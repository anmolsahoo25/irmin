open Astring

module Conf = struct
  include Irmin.Backend.Conf

  let spec = Spec.v "scylla"

  let ip_key = key ~spec "ip" Irmin.Type.string "0.0.0.0"

  let port_key = key ~spec "port" Irmin.Type.string "9042"
end

let config ip port =
  let c1 = Conf.(verify (add (empty Conf.spec) Conf.ip_key ip)) in 
  Conf.(verify (add c1 Conf.port_key port))

module Read_only (K : Irmin.Type.S) (V : Irmin.Type.S) = struct

  type key = K.t 
  type value = V.t

  type -'a t = 'a Scylla.conn

  let v config =
    let sw, net = Irmin.Backend.Conf.Env.net () in 
    let ip = Conf.get config Conf.ip_key in 
    let port = Conf.get config Conf.port_key |> String.to_int |> Option.get in
    let t = Scylla.connect sw net ip port |> Result.get_ok in
    let t = (t :> Irmin.Perms.read t) in
    t

  let find t key =
    let open Scylla in
    let key_string = Protocol.Varchar (Irmin.Type.to_string K.t key) in
    let rows =
      query t
            ~query:"SELECT value from keyspace1.append_only_store where key = ?"
            ~values:[key_string] ()
            |> Result.get_ok
    in 
    match rows.values with
    | [[ Protocol.Varchar value_string ]] -> Some (Irmin.Type.of_string V.t value_string |> Result.get_ok)
    | [ ] -> None
    | _ -> failwith "unreachable"

  let mem t k =
    if Option.is_some (find t k) then true else false

  let close _t = ()
end

module Append_only (K : Irmin.Type.S) (V : Irmin.Type.S) = struct
  include Read_only (K) (V)

  let add t key value =
    let open Scylla in
    let key_string = Protocol.Varchar (Irmin.Type.to_string K.t key) in 
    let value_string = Protocol.Varchar (Irmin.Type.to_string V.t value) in 
    let _ = query t
                  ~query:"INSERT INTO keyspace1.append_only_store(key,value) VALUES (?,?)" 
                  ~values:[key_string ; value_string] ()
    in
    ()

  let batch (t : Irmin.Perms.Read.t t) f = f (t |> Obj.repr |> Obj.magic)
end

module Atomic_write (K : Irmin.Type.S) (V : Irmin.Type.S) = struct
  module RO = Read_only (K) (V)
  module W = Irmin.Backend.Watch.Make (K) (V)

  type t = { t : Irmin.Perms.Read.t RO.t ; w : W.t }
  type key = RO.key
  type value = RO.value
  type watch = W.watch * (unit -> unit)

  let v config = { t = RO.v config ; w = W.v () }

  let close _t = ()

  let find t key =
    let open Scylla in
    let key_string = Protocol.Varchar (Irmin.Type.to_string K.t key) in
    let rows =
      query t.t
            ~query:"SELECT value from keyspace1.atomic_store where key = ?"
            ~values:[key_string] ()
            |> Result.get_ok
    in 
    match rows.values with
    | [[ Protocol.Varchar value_string ]] -> Some (Irmin.Type.of_string V.t value_string |> Result.get_ok)
    | [ ] -> None
    | _ -> failwith "unreachable"

  let mem t k =
    if Option.is_some (find t k) then true else false

  let set t key value =
    let open Scylla in 
    let key_string = Protocol.Varchar (Irmin.Type.to_string K.t key) in
    let value_string = Protocol.Varchar (Irmin.Type.to_string V.t value) in 
    let _ = query t.t
                  ~query:"UPDATE keyspace1.atomic_store set value = ? WHERE key = ?"
                  ~values:[value_string ; key_string]
                  ()
    in
    ()

  let test_and_set t key ~test ~set =
    let open Scylla in
    if Option.is_none test then (
      let key_string = Protocol.Varchar (Irmin.Type.to_string K.t key) in 
      let set_string = Protocol.Varchar (Irmin.Type.to_string V.t (set |> Option.get)) in
      let _ = query t.t 
                  ~query:"UPDATE keyspace1.atomic_store set value = ? WHERE key = ?"
                  ~values:[set_string ; key_string ]
                  ()
      in true
    ) else (
      let key_string = Protocol.Varchar (Irmin.Type.to_string K.t key) in 
      let test_string = Protocol.Varchar (Irmin.Type.to_string V.t (test |> Option.get)) in
      let set_string = Protocol.Varchar (Irmin.Type.to_string V.t (set |> Option.get)) in
      let _ = query t.t 
                  ~query:"UPDATE keyspace1.atomic_store set value = ? WHERE key = ? IF value = ?"
                  ~values:[set_string ; key_string ; test_string ]
                  ()
      in true
    )

  let remove _t _key = ()

  let list t =
    let open Scylla in 
    let rows = query t.t ~query:"SELECT key from keyspace1.atomic_store" () |> Result.get_ok in
    List.map (function [Protocol.Varchar s] -> (Irmin.Type.of_string K.t s |> Result.get_ok) | _ -> failwith "got non varchar from table") rows.values

  let watch t ?init f =
    (W.watch t.w ?init f, fun () -> ())

  let watch_key t key ?init f =
    let w = W.watch_key t.w key ?init f in 
    (w, fun () -> ())

  let unwatch _t (_id, _stop) = ()

  let clear _t = ()

end

module Content_addressable = Irmin.Content_addressable.Make (Append_only)
module Maker = Irmin.Maker (Content_addressable) (Atomic_write)
module KV = Irmin.KV_maker (Content_addressable) (Atomic_write)

module Maker_is_a_maker : Irmin.Maker = Maker

module KV_is_a_KV : Irmin.KV_maker = KV

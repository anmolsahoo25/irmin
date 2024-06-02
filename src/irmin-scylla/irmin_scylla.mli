module Conf : sig 
  open Irmin.Backend.Conf 

  val spec : Spec.t
end

val config : string -> string -> Irmin.config
(** configure the host ip and port for the store *)

module Read_only : Irmin.Read_only.Maker
module Append_only : Irmin.Append_only.Maker
module Atomic_write : Irmin.Atomic_write.Maker
module Maker : Irmin.Maker
module KV : Irmin.KV_maker with type info = Irmin.Info.default

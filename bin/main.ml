open Lwt.Infix

let () =
  Logs.set_reporter (Logs_fmt.reporter ())

let ( / ) = Filename.concat

(*
module Store = Obuilder.Zfs_store
let store = Lwt_main.run @@ Store.create ~pool:"tank"
*)

module Sandbox = Obuilder.Sandbox

type builder = Builder : (module Obuilder.BUILDER with type t = 'a) * 'a -> builder

let log tag msg =
  match tag with
  | `Heading -> Fmt.pr "%a@." Fmt.(styled (`Fg (`Hi `Blue)) string) msg
  | `Note -> Fmt.pr "%a@." Fmt.(styled (`Fg `Yellow) string) msg
  | `Output -> output_string stdout msg; flush stdout

let create_builder config spec =
  Obuilder.Store_spec.to_store spec >|= fun (Store ((module Store), store)) -> 
  let module Builder = Obuilder.Builder(Store)(Sandbox) in
  let sandbox = Sandbox.create config in
  let builder = Builder.v ~store ~sandbox in
  Builder ((module Builder), builder)

let build store spec src_dir config =
  Lwt_main.run begin
    create_builder config store >>= fun (Builder ((module Builder), builder)) ->
    let spec = Obuilder.Spec.t_of_sexp (Sexplib.Sexp.load_sexp spec) in
    let context = Obuilder.Context.v ~log ~src_dir () in
    Builder.build builder context spec >>= function
    | Ok x ->
      Fmt.pr "Got: %S@." (x :> string);
      Lwt.return_unit
    | Error `Cancelled ->
      Fmt.epr "Cancelled at user's request@.";
      exit 1
    | Error (`Msg m) ->
      Fmt.epr "Build step failed: %s@." m;
      exit 1
  end

let healthcheck conf verbose store =
  if verbose then
    Logs.Src.set_level Obuilder.log_src (Some Logs.Info);
  Lwt_main.run begin
    create_builder conf store >>= fun (Builder ((module Builder), builder)) ->
    Builder.healthcheck builder >|= function
    | Error (`Msg m) ->
      Fmt.epr "Healthcheck failed: %s@." m;
      exit 1
    | Ok () ->
      Fmt.pr "Healthcheck passed@."
  end

let delete store conf id =
  Lwt_main.run begin
    create_builder conf store >>= fun (Builder ((module Builder), builder)) ->
    Builder.delete builder id ~log:(fun id -> Fmt.pr "Removing %s@." id)
  end

let dockerfile buildkit spec =
  Sexplib.Sexp.load_sexp spec
  |> Obuilder_spec.t_of_sexp
  |> Obuilder_spec.Docker.dockerfile_of_spec ~buildkit
  |> print_endline

open Cmdliner

let spec_file =
  Arg.required @@
  Arg.opt Arg.(some file) None @@
  Arg.info
    ~doc:"Path of build spec file"
    ~docv:"FILE"
    ["f"]

let src_dir =
  Arg.required @@
  Arg.pos 0 Arg.(some dir) None @@
  Arg.info
    ~doc:"Directory containing the source files"
    ~docv:"DIR"
    []

let store_t =
  Arg.conv Obuilder.Store_spec.(of_string, pp)

let store =
  Arg.required @@
  Arg.opt Arg.(some store_t) None @@
  Arg.info
    ~doc:"zfs:pool or btrfs:/path for build cache"
    ~docv:"STORE"
    ["store"]

let id =
  Arg.required @@
  Arg.pos 0 Arg.(some string) None @@
  Arg.info
    ~doc:"The ID of a build within the store"
    ~docv:"ID"
    []

let build =
  let doc = "Build a spec file." in
  Term.(const build $ store $ spec_file $ src_dir $ Sandbox.cmdliner),
  Term.info "build" ~doc

let delete =
  let doc = "Recursively delete a cached build result." in
  Term.(const delete $ store $ Sandbox.cmdliner $ id),
  Term.info "delete" ~doc

let buildkit =
  Arg.value @@
  Arg.flag @@
  Arg.info
    ~doc:"Output extended BuildKit syntax"
    ["buildkit"]

let dockerfile =
  let doc = "Convert a spec to Dockerfile format" in
  Term.(const dockerfile $ buildkit $ spec_file),
  Term.info "dockerfile" ~doc

let version = 
  let print () = Format.printf "%s\n" Sandbox.version in 
  let doc = "Print the type of sandboxing environment being used" in 
  Term.(const print $ pure ()), Term.info "version" ~doc

let verbose =
  Arg.value @@
  Arg.flag @@
  Arg.info
    ~doc:"Enable verbose logging"
    ["verbose"]

let healthcheck =
  let doc = "Perform a self-test" in
  Term.(const healthcheck $ Sandbox.cmdliner $ verbose $ store),
  Term.info "healthcheck" ~doc

let cmds = [build; delete; dockerfile; version]

let default_cmd =
  let doc = "a command-line interface for OBuilder" in
  Term.(ret (const (`Help (`Pager, None)))),
  Term.info "obuilder" ~doc

let term_exit (x : unit Term.result) = Term.exit x

let () =
  (* Logs.(set_level (Some Info)); *)
  Fmt_tty.setup_std_outputs ();
  term_exit @@ Term.eval_choice default_cmd cmds
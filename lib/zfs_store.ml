open Lwt.Infix

(* This is rather complicated, because (unlike btrfs):
   - zfs won't let you delete datasets that other datasets are cloned from.
     However, you can "promote" a dataset, so that it switches roles with its parent.
   - Some zfs commands use "--" to separate options from arguments, but others interpret it as an argument!
   - Sometimes we need "datasets" and at other times we need pathnames (the difference is a leading '/')

   Example of zfs promotion:

   1. Create ds1.
   2. Create snapshots ds1@snap1, ds1@snap2, ds1@snap3.
   3. Create clones of ds1@snap2: clone1, clone2, clone3.

   At this point:
   - ds1 has clones {clone1, clone2, clone3} and snapshots {snap1, snap2, snap3}.

   4. Promote clone2.

   Now:
   - clone2 has clones {clone1, ds1, clone3} and snapshots {snap1, snap2}.
   - ds1 has no clones and snapshots {snap3}.
*)

let strf = Printf.sprintf

type cache = {
  lock : Lwt_mutex.t;
  mutable gen : int;            (* Version counter. *)
  mutable n_clones : int;
}

type t = {
  pool : string;
  prefix: string;
  caches : (string, cache) Hashtbl.t;
  mutable next : int;
}

let default_snapshot = "snap"

module Dataset : sig
  type dataset

  val state : dataset
  val cache_tmp_group : dataset
  val groups : dataset list

  val result : S.id -> dataset
  val cache : string -> dataset
  val cache_tmp : int -> string -> dataset

  val full_name : ?snapshot:string -> t -> dataset -> string
  val path : ?snapshot:string -> t -> dataset -> string

  val exists : ?snapshot:string -> t -> dataset -> bool
  val if_missing : ?snapshot:string -> t -> dataset -> (unit -> unit Lwt.t) -> unit Lwt.t
end = struct
  type dataset = string

  let state = "state"
  let result_group = "result"
  let cache_group = "cache"
  let cache_tmp_group = "cache-tmp"

  let groups = [state; result_group; cache_group; cache_tmp_group]

  let result id = "result/" ^ id
  let cache name = "cache/" ^ Escape.cache name
  let cache_tmp i name = strf "cache-tmp/%d-%s" i (Escape.cache name)

  let full_name ?snapshot t ds =
    match snapshot with
    | None -> strf "%s/%s" t.pool ds
    | Some snapshot -> strf "%s/%s@%s" t.pool ds snapshot

  let path ?snapshot t ds =
    match snapshot with
    | None -> strf "%s/%s/%s" t.prefix t.pool ds
    | Some snapshot -> strf "%s/%s/%s/.zfs/snapshot/%s" t.prefix t.pool ds snapshot

  let exists ?snapshot t ds =
    match Os.check_dir (path ?snapshot t ds) with
    | `Missing -> false
    | `Present -> true

  let if_missing ?snapshot t ds fn =
    if exists ?snapshot t ds then Lwt.return_unit
    else fn ()
end

let user = { Obuilder_spec.uid = 500; gid = 1000 }

module Zfs = struct
  let chown ~user t ds =
    let { Obuilder_spec.uid; gid } = user in
    Os.sudo ["chown"; strf "%d:%d" uid gid; Dataset.path t ds]

  let chmod mode t ds =
    Os.sudo ["chmod"; mode; Dataset.path t ds]

  let create t ds =
    Log.info (fun f -> f "Creating %s\n" (Dataset.full_name t ds));
    Os.sudo ["zfs"; "create"; "--"; Dataset.full_name t ds]

  let list_snapshots t ds = 
    Os.pread ["zfs"; "list"; "-t"; "snapshot"; "-o"; "name"] >|= String.split_on_char '\n' >|= fun res -> 
      match res with 
        | _::rest -> rest 
        | _ -> []

  let get_snap ~snapshot t id = 
    let ds = Dataset.result id in
    let path = Dataset.full_name t ds ~snapshot in
    list_snapshots t ds >|= fun snaps -> 
    Log.debug (fun f -> f "Looking for: %s in [%a]" path Fmt.(list string) snaps);
    if List.exists (String.equal path) snaps then Some path else None 

  let get_snap_from_path ~snapshot t ds = 
    let path = Dataset.full_name t ds ~snapshot in
    list_snapshots t ds >|= fun snaps -> 
    Log.debug (fun f -> f "Looking for: %s in [%a]" path Fmt.(list string) snaps);
    if List.exists (String.equal path) snaps then Some path else None 

  let destroy ?(force=true) t ds mode =
    let opts =
      match mode with
      | `Only -> []
      | `And_snapshots -> ["-r"]
      | `And_snapshots_and_clones -> ["-R"]
    in
    let opts = if force then "-f" :: opts else opts in 
    Log.info (fun f -> f "Destroying %s\n" (Dataset.full_name t ds));
    Os.sudo (["zfs"; "destroy"] @ opts @ ["--"; Dataset.full_name t ds])

  let destroy_result ?(force=false) t ds mode =
    let opts =
      match mode with
      | `Only -> []
      | `And_snapshots -> ["-r"]
      | `And_snapshots_and_clones -> ["-R"]
    in
    let opts = if force then "-f" :: opts else opts in 
    Os.sudo_result ~pp:(fun ppf -> Fmt.pf ppf "Destroying %s" (Dataset.full_name t ds)) (["zfs"; "destroy"] @ opts @ ["--"; Dataset.full_name t ds])

  let destroy_snapshot t ds snapshot mode =
    let opts =
      match mode with
      | `Defer -> ["-d"]
      | `Recurse -> ["-R"]
      | `Immediate -> []
    in
    Log.info (fun f -> f "Destroying snapshot %s\n" (Dataset.full_name t ds ^ "@" ^ snapshot));
    Os.sudo (["zfs"; "destroy"] @ opts @ ["--"; Dataset.full_name t ds ^ "@" ^ snapshot])

  let clone t ~src ~snapshot dst =
    Log.info (fun f -> f "Cloning %s\n" (Dataset.full_name t dst));
    Os.sudo ["zfs"; "clone"; "--"; Dataset.full_name t src ~snapshot; Dataset.full_name t dst]

  let snapshot t ds ~snapshot =
    Log.info (fun f -> f "Snapshotting %s\n" (Dataset.full_name t ds));
    Os.sudo ["zfs"; "snapshot"; Dataset.full_name t ds ~snapshot]

  let promote t ds =
    Log.info (fun f -> f "Promoting %s\n" (Dataset.full_name t ds));
    Os.sudo ["zfs"; "promote"; Dataset.full_name t ds]

  let rename t ~old ds =
    Log.info (fun f -> f "Rename from %s to %s\n" (Dataset.full_name t old) (Dataset.full_name t ds));
    Os.sudo ["zfs"; "rename"; "-f"; "--"; Dataset.full_name t old; Dataset.full_name t ds]

  let rename_snapshot t ds ~old snapshot =
    Log.info (fun f -> f "Rename snap from %s to %s\n" (Dataset.full_name t ds ~snapshot:old) (Dataset.full_name t ds ~snapshot));
    Os.sudo ["zfs"; "rename"; "--";
          Dataset.full_name t ds ~snapshot:old;
          Dataset.full_name t ds ~snapshot]

  let mount t ds snapshot = 
    Os.sudo_result ~pp:(fun ppf -> Fmt.pf ppf "Mounting snap %s" (Dataset.full_name t ds ~snapshot)) 
    ["zfs"; "mount"; (Dataset.full_name t ds ~snapshot)]

  let unmount t ds snapshot = 
    Os.sudo_result ~pp:(fun ppf -> Fmt.pf ppf "Unmounting snap %s" (Dataset.full_name t ds ~snapshot)) 
    ["zfs"; "unmount"; (Dataset.full_name t ds ~snapshot)]
end

let exists ?snapshot t ds =
  match snapshot with 
    | Some _ as snapshot ->
      Zfs.(mount t ds default_snapshot) >>= fun _ ->
      Lwt.return @@ Dataset.exists ?snapshot t ds >>= fun b -> 
      Zfs.(unmount t ds default_snapshot) >>= fun _ ->
      Lwt.return b
    | None -> Lwt.return @@ Dataset.exists t ds

let if_missing ?snapshot t ds fn =
  exists ?snapshot t ds >>= fun b -> 
  if b then Lwt.return_unit
  else fn ()
  
let delete_if_exists t ds mode =
  (* For checkdir to find the snap shot it must be mounted *)
  exists t ds >>= fun b -> 
  if b then begin  
    (Log.info (fun f -> f "Deleting %s\n" (Dataset.full_name t ds)); Zfs.destroy t ds mode)
  end else 
    Lwt.return_unit

let ( / ) = Filename.concat

let state_dir t = Dataset.path t Dataset.state

let create ~prefix ~pool = 
  let prefix = match prefix with Some p -> "/" ^ p | None -> "/" in 
  let t = { pool; prefix; caches = Hashtbl.create 10; next = 0 } in
  (* Ensure any left-over temporary datasets are removed before we start. *)
  delete_if_exists t (Dataset.cache_tmp_group) `And_snapshots_and_clones >>= fun () ->
  Dataset.groups |> Lwt_list.iter_s (fun group ->
      if_missing t group (fun () -> Zfs.create t group) >>= fun () ->
      Zfs.chown ~user t group
    ) >>= fun () ->
  Lwt.return t

(* The builder will always delete child datasets before their parent.
   It's possible that we crashed after cloning this but before recording that
   in the database. So any clones of this dataset must be unregistered junk. *)
let delete t id =
  delete_if_exists t (Dataset.result id) `And_snapshots_and_clones

(* We start by either creating a new dataset or by cloning base@snap (if [base] is given).
   On success, we snapshot the clone as clone@snap.
   On failure, we destroy the clone. This will always succeed because we can't have
   tagged it or created further clones at this point. *)
let build t ?base ~id fn =
  Log.debug (fun f -> f "zfs: build %S" id);
  let ds = Dataset.result id in
  (* We have to create the dataset in its final location because ZFS can't
     rename it while we have the log file open (which we need to do). But
     we don't create the snapshot unless the build succeeds. If we crash
     with a partially written directory, `result` will see there is no
     snapshot and we'll end up here and delete it. *)
  delete_if_exists t ds `Only >>= fun () ->
  let clone = Dataset.path t ds in
  begin match base with
    | None ->
      Zfs.create t ds >>= fun () ->
      Zfs.chown ~user t ds >>= fun () -> 
      Zfs.chmod "g+w" t ds 
    | Some base ->
      let src = Dataset.result base in
      Zfs.clone t ~src ~snapshot:default_snapshot ds
  end
  >>= fun () ->
  Lwt.try_bind
    (fun () -> fn clone)
    (function
      | Ok () ->
        Log.debug (fun f -> f "zfs: build %S succeeded" id);
        Zfs.snapshot t ds ~snapshot:default_snapshot >>= fun () ->
        (* ZFS can't delete the clone while the snapshot still exists. So I guess we'll just
           keep it around? *)
        Lwt_result.return ()
      | Error _ as e ->
        Log.info (fun f -> f "zfs: build %S failed" id);
        let rec aux () =
          Zfs.destroy_result ~force:false t ds `Only >>= (function 
            | Ok _ -> Lwt.return e
            | Error (`Msg m) -> Log.info (fun f -> f "Error: %s" m); Lwt_unix.sleep 5. >>= fun () -> aux ())
        in aux ()
    )
    (fun ex ->
        Log.warn (fun f -> f "Uncaught exception from %S build function: %a" id Fmt.exn ex);
        raise ex
    )

let check_snap ~snapshot t id = 
  Zfs.get_snap ~snapshot:default_snapshot t id >|= Option.is_some

let result t id =
  let ds = Dataset.result id in
  (* Will only work if we mount the directory... when do we unmount it... *)
  let path = Dataset.path t ds ~snapshot:default_snapshot in
  let name = Dataset.full_name t ds ~snapshot:default_snapshot in 
  Zfs.list_snapshots t ds >>= fun snaps -> 
  if List.exists (String.equal name) snaps then 
    begin 
      Zfs.mount t ds default_snapshot >|= fun _ ->
      Some path 
    end 
  else 
    begin 
      Log.info (fun f -> f "Didn't find %s in [%a]" name (Fmt.(list string)) snaps);
      Lwt.return None
    end 

let get_cache t name =
  match Hashtbl.find_opt t.caches name with
  | Some c -> c
  | None ->
    let c = { lock = Lwt_mutex.create (); gen = 0; n_clones = 0 } in
    Hashtbl.add t.caches name c;
    c

(* Return the name of an unused temporary dataset, based on [name]. *)
let get_tmp_ds t name =
  let tmp_ds = Dataset.cache_tmp t.next name in
  t.next <- t.next + 1;
  tmp_ds

(* Properties you can assume after taking the lock:

   - Either we have a dataset with the latest snapshot of the cache
     (main@snap), or it doesn't exist yet (in which case we create it and
     snapshot immediately).

   - Any other tags on main are marked for deletion, but some clones
     still depend on them. They will all be older than "snap".

   - There may be clones of main. These clones have no snapshots, and no
     further sub-clones.

   We clone main@snap, and then let the user write to that (tmp) with the lock
   released.

   When the user releases tmp, we retake the lock and then either:

   - Destroy tmp, or
   - Replace main with tmp (see comments in code).

   Crash recovery:

   - We might crash before making the main@snap tag. If main is missing this tag,
     it is safe to create it, since we must have been just about to do that.
*)
let cache ~user t name : (string * (unit -> unit Lwt.t)) Lwt.t =
  let cache = get_cache t name in
  Lwt_mutex.with_lock cache.lock @@ fun () ->
  Log.debug (fun f -> f "zfs: get cache %S" (name :> string));
  let gen = cache.gen in
  let main_ds = Dataset.cache name in
  let tmp_ds = get_tmp_ds t name in
  (* Create the cache as an empty directory if it doesn't exist. *)
  if_missing t main_ds (fun  () -> Zfs.create t main_ds) >>= fun () ->
  (* Ensure we have the snapshot. This is needed on first creation, and
     also to recover from crashes. *)
  if_missing t main_ds ~snapshot:default_snapshot (fun () ->
    Zfs.chown ~user t main_ds >>= fun () ->
    Zfs.snapshot t main_ds ~snapshot:default_snapshot
  ) >>= fun () ->
  cache.n_clones <- cache.n_clones + 1;
  Zfs.clone t ~src:main_ds ~snapshot:default_snapshot tmp_ds >>= fun () ->
  let release () =
    Lwt_mutex.with_lock cache.lock @@ fun () ->
    Log.debug (fun f -> f "zfs: release cache %S" (name :> string));
    cache.n_clones <- cache.n_clones - 1;
    if cache.gen = gen then (
      (* main_ds hasn't changed since we cloned it. Update it. *)
      (* todo: check if tmp_ds has changed. *)
      cache.gen <- cache.gen + 1;
      (* Rename main to something temporary, so if we crash here then we'll
         just start again with an empty cache next time. *)
      let delete_me = get_tmp_ds t name in
      Zfs.rename t ~old:main_ds delete_me >>= fun () ->
      Zfs.promote t tmp_ds >>= fun () ->
      (* At this point:
         - All the other clones of main are now clones of tmp_ds.
         - main@snap has moved to tmp@snap.
         - Any other tags were older than snap and so have also moved to tmp. *)
      Zfs.destroy t delete_me `Only >>= fun () ->
      (* Move the old @snap tag out of the way. *)
      let archive_name = strf "old-%d" gen in
      (* We know [archive_name] doesn't exist because [gen] is unique for
         this process, and we delete stale tmp dirs from previous runs at start-up,
         which would remove any such deferred tags. *)
      Zfs.rename_snapshot t tmp_ds ~old:default_snapshot archive_name >>= fun () ->
      (* Mark the archived snapshot for removal. If other clones are using it,
         this will defer the deletion until they're done *)
      Zfs.destroy_snapshot t tmp_ds archive_name `Defer >>= fun () ->
      (* Create the new snapshot and rename this as the new main_ds. *)
      Zfs.snapshot t tmp_ds ~snapshot:default_snapshot >>= fun () ->
      Zfs.rename t ~old:tmp_ds main_ds
    ) else (
      (* We have no snapshots or clones here. *)
      Lwt.catch (fun () -> Zfs.destroy t tmp_ds `Only)
        (fun ex ->
           Log.warn (fun f -> f "Error trying to release cache (will retry): %a" Fmt.exn ex);
           (* XXX: Don't know what's causing this. By the time fuser runs, the problem has disappeared! *)
           Unix.system (strf "fuser -mv %S" (Dataset.path t tmp_ds)) |> ignore;
           Lwt_unix.sleep 10.0 >>= fun () ->
           Zfs.destroy t tmp_ds `Only
        )
    )
  in
  Lwt.return (Dataset.path t tmp_ds, release)

let delete_cache t name =
  let cache = get_cache t name in
  Lwt_mutex.with_lock cache.lock @@ fun () ->
  Log.debug (fun f -> f "zfs: delete_cache %S" (name :> string));
  if cache.n_clones > 0 then Lwt_result.fail `Busy
  else (
    let main_ds = Dataset.cache name in
    exists t main_ds >>= fun b -> 
    if b then (
      Zfs.destroy t main_ds `And_snapshots >>= fun () ->
      Lwt_result.return ()
    ) else Lwt_result.return ()
  )

let complete_deletes _t =
  (* The man-page says "Pending changes are generally accounted for within a few seconds" *)
  Lwt_unix.sleep 5.0

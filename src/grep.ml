(* SPDX-License-Identifier: MIT *)

module Cmd = Bos.Cmd
module Exec = Bos.OS.Cmd
module Dir = Bos.OS.Dir
module Path = Bos.OS.Path

let ( // ) = Fpath.( / )
let ( % ) = Cmd.( % )
let ( %% ) = Cmd.( %% )

exception OpamGrepError of string

let result = function
  | Ok x -> x
  | Error (`Msg msg) -> raise (OpamGrepError msg)

let list_split_bunch n l =
  let rec aux i acc = function
    | [] -> (acc, [])
    | x::xs when i < n -> aux (succ i) (x :: acc) xs
    | l -> (acc, l)
  in
  let rec accu acc l =
    match aux 0 [] l with
    | (x, []) -> x :: acc
    | (x, (_::_ as rest)) -> accu (x :: acc) rest
  in
  accu [] l

let dst () =
  let cachedir =
    match Sys.getenv_opt "XDG_CACHE_HOME" with
    | Some cachedir -> Fpath.v cachedir
    | None ->
        match Sys.getenv_opt "HOME" with
        | Some homedir -> Fpath.v homedir // ".cache"
        | None -> raise (OpamGrepError "Cannot find your home directory")
  in
  cachedir // "opam-grep"

let sync ~repos ~depends_on ~dst =
  let repos = match repos with
    | None -> Cmd.empty
    | Some repos -> Cmd.empty % ("--repos="^repos)
  in
  let depends_on = match depends_on with
    | None -> Cmd.empty
    | Some depends_on -> Cmd.empty % "--recursive" % ("--depends-on="^depends_on)
  in
  let _exists : bool = result (Dir.create ~path:true dst) in
  let pkgs_bunch =
    (Cmd.v "opam" % "list" % "-A" % "-s" % "--color=never" %% repos %% depends_on) |>
    Exec.run_out |>
    Exec.out_lines |>
    Exec.success |>
    result |>
    list_split_bunch 255 (* NOTE: Smallest value of MAX_ARG: https://www.in-ulm.de/~mascheck/various/argmax/ *)
  in
  let opam_show pkgs =
    (Cmd.v "opam" % "show" % "--color=never" % "-f" % "package" %% Cmd.of_list pkgs) |>
    Exec.run_out |>
    Exec.out_lines |>
    Exec.success |>
    result
  in
  List.map opam_show pkgs_bunch |> List.concat |> List.sort_uniq String.compare

(* Fetch the sources of [pkgs] into [dst], running at most [jobs] [opam source]
   processes at once. Each package is fetched into its own temporary directory
   and only moved to [dst/pkg] once complete, so a package directory is never
   observed half-written. [on_ready] is called with the directory of each
   package as soon as it is available; packages that fail are skipped. *)
let fetch_all ~jobs ~dst ~on_ready ~on_skip pkgs =
  let tmproot = dst // "tmp" in
  result (Dir.delete ~recurse:true tmproot);
  let _exists : bool = result (Dir.create ~path:true tmproot) in
  let devnull = Unix.openfile "/dev/null" [Unix.O_RDWR] 0 in
  Fun.protect ~finally:(fun () -> Unix.close devnull) @@ fun () ->
  let running = Hashtbl.create jobs in
  let spawn pkg =
    let tmpdir = tmproot // pkg in
    let argv = [| "opam"; "source"; "--dir"; Fpath.to_string tmpdir; pkg |] in
    let pid = Unix.create_process "opam" argv devnull devnull devnull in
    Hashtbl.replace running pid (pkg, tmpdir)
  in
  let rec wait_one () =
    match Unix.wait () with
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait_one ()
    | (pid, status) ->
        match Hashtbl.find_opt running pid with
        | None -> wait_one ()
        | Some (pkg, tmpdir) ->
            Hashtbl.remove running pid;
            match status with
            | Unix.WEXITED 0 ->
                let pkgdir = dst // pkg in
                result (Path.move tmpdir pkgdir);
                on_ready pkg pkgdir
            | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ ->
                (* ignore errors, e.g. bad checksum, failed to fetch, etc. *)
                result (Dir.delete ~recurse:true tmpdir);
                on_skip pkg
  in
  List.iter begin fun pkg ->
    let pkgdir = dst // pkg in
    if result (Dir.exists pkgdir) then
      on_ready pkg pkgdir
    else begin
      if Int.compare (Hashtbl.length running) jobs >= 0 then wait_one ();
      spawn pkg
    end
  end pkgs;
  while Int.compare (Hashtbl.length running) 0 > 0 do wait_one () done

let greps = [
  Cmd.v "rg"; (* ripgrep (fast, rust) *)
  Cmd.v "ugrep"; (* ugrep (fast, C++) *)
  Cmd.v "grep" (* grep (posix-ish) *)
]

let get_grep_cmd () =
  match List.find_opt (fun grep -> result (Exec.exists grep)) greps with
  | Some grep -> grep
  | None -> raise (OpamGrepError "Could not find any grep command")

let bar ~total =
  let module Line = Progress.Line in
  Line.list [ Line.spinner (); Line.bar total; Line.count_to total ]

let search ~jobs ~repos ~depends_on ~regexp =
  let dst = dst () in
  prerr_endline "[Info] Getting the list of all known opam packages..";
  let pkgs = sync ~repos ~depends_on ~dst in
  let grep = get_grep_cmd () in
  prerr_endline ("[Info] Fetching and grepping using "^Cmd.get_line_tool grep^"..");
  Progress.with_reporter (bar ~total:(List.length pkgs)) begin fun progress ->
    let on_ready pkg pkgdir =
      progress 1;
      match Exec.run (grep % "--binary" % "-qsr" % "-e" % regexp % Fpath.to_string pkgdir) with
      | Ok () ->
          let pkg = List.hd (String.split_on_char '.' pkg) in
          Progress.interject_with begin fun () ->
            print_endline (pkg^" matches your regexp.")
          end
      | Error _ -> () (* Ignore errors here *)
    in
    let on_skip _pkg = progress 1 in
    fetch_all ~jobs ~dst ~on_ready ~on_skip pkgs
  end

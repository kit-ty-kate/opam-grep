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

let check ~dst pkg =
  let tmpdir = dst // "tmp" in
  let pkgdir = dst // pkg in
  if not (result (Dir.exists pkgdir)) then begin
    result (Dir.delete ~recurse:true tmpdir);
    let outcome =
      (Cmd.v "opam" % "source" % "--dir" % Fpath.to_string tmpdir % pkg) |>
      Exec.run_out ~err:Exec.err_null |>
      Exec.out_null |>
      Exec.success
    in
    match outcome with
    | Ok () ->
        result (Path.move tmpdir pkgdir);
        Some pkgdir
    | Error _ ->
        (* ignore errors, e.g. bad checksum, failed to fetch, etc. *)
        None
  end else
    Some pkgdir

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

let search ~repos ~depends_on ~regexp =
  let dst = dst () in
  prerr_endline "[Info] Getting the list of all known opam packages..";
  let pkgs = sync ~repos ~depends_on ~dst in
  let grep = get_grep_cmd () in
  prerr_endline ("[Info] Fetching and grepping using "^Cmd.get_line_tool grep^"..");
  Progress.with_reporter (bar ~total:(List.length pkgs)) begin fun progress ->
    List.iter begin fun pkg ->
      progress 1;
      match check ~dst pkg with
      | None -> ()
      | Some pkgdir ->
        match Exec.run (grep % "--binary" % "-qsr" % "-e" % regexp % Fpath.to_string pkgdir) with
        | Ok () ->
            let pkg = List.hd (String.split_on_char '.' pkg) in
            Progress.interject_with begin fun () ->
              print_endline (pkg^" matches your regexp.")
            end
        | Error _ -> () (* Ignore errors here *)
    end pkgs;
  end

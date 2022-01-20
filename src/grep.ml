(* SPDX-License-Identifier: MIT *)

module Cmd = Bos.Cmd
module Exec = Bos.OS.Cmd
module Dir = Bos.OS.Dir
module Path = Bos.OS.Path

let ( // ) = Fpath.( / )
let ( % ) = Cmd.( % )

exception OpamGrepError of string

let dirname_of_fpath dir = OpamFilename.Dir.of_string (Fpath.to_string dir)

let result = function
  | Ok x -> x
  | Error (`Msg msg) -> raise (OpamGrepError msg)

let dst () =
  let cachedir =
    match Sys.getenv_opt "XDG_CACHE_HOME" with
    | Some cachedir -> Fpath.v cachedir
    | None ->
        match Sys.getenv_opt "HOME" with
        | Some homedir -> Fpath.v homedir // ".cache"
        | None -> raise (OpamGrepError "Cannot find your home directory")
  in
  cachedir // "opam-grep-dra27"

let sync ~dst =
  let dst = dst // ".opam-repository" in
  let () =
    if result (Dir.exists dst) then
      (Cmd.v "git" % "-C" % Fpath.to_string dst % "pull" % "origin") |>
      Exec.run_out |>
      Exec.out_null |>
      Exec.success |>
      result
    else
      (Cmd.v "git" % "clone" % "https://github.com/ocaml/opam-repository.git" % Fpath.to_string dst) |>
      Exec.run_out |>
      Exec.out_null |>
      Exec.success |>
      result
  in
  let repo = dirname_of_fpath dst in
  let packages =
    (* XXX If there isn't an OpamRepository function to do this, there should be! *)
    let f package prefix latest =
      let open OpamPackage in
      try
        if OpamPackage.Version.compare package.version (fst (OpamPackage.Name.Map.find package.name latest)).version = 1 then
          OpamPackage.Name.Map.add package.name (package, prefix) latest
        else
          latest
      with Not_found -> OpamPackage.Name.Map.add package.name (package, prefix) latest
    in
    OpamPackage.Map.fold f (OpamRepository.packages_with_prefixes repo) OpamPackage.Name.Map.empty
  in
  let load _ (package, prefix) packages =
    let opam = OpamFile.OPAM.read (OpamRepositoryPath.opam repo prefix package) in
    (*begin match opam.OpamFile.OPAM.metadata_dir with
    | Some (None, s) -> Printf.printf "Yes: %s\n%!" s
    | Some (_, _) -> Printf.printf "WTF\n%!"
    | None -> Printf.printf "No\n%!"
    end;*)
    OpamPackage.Map.add package opam packages
  in
  OpamPackage.Name.Map.fold load packages OpamPackage.Map.empty

let check ~opams ~dst pkg =
  let tmpdir = dst // "tmp" in
  let pkgdir = dst // (OpamPackage.to_string pkg) in
  if not (result (Dir.exists pkgdir)) then begin
    result (Dir.delete ~recurse:true tmpdir);
    let job =
      let open OpamProcess.Job.Op in
      let root = dirname_of_fpath (dst // ".opam") in
      let gt = OpamStateTypes.{global_lock = OpamSystem.lock_none; root; config = OpamFile.Config.empty; global_variables = OpamVariable.Map.empty} in
      let rt = OpamStateTypes.{repos_lock = OpamSystem.lock_none; repos_global = gt; repositories = OpamRepositoryName.Map.empty; repos_definitions = OpamRepositoryName.Map.empty; repo_opams = OpamRepositoryName.Map.empty; repos_tmp = Hashtbl.create 15} in
      let t = OpamStateTypes.{switch_lock = OpamSystem.lock_none; switch_global = gt; switch_repos = rt; switch = OpamSwitch.unset; switch_invariant = OpamFormula.Empty; compiler_packages = OpamPackage.Set.empty; switch_config = OpamFile.Switch_config.empty; repos_package_index = OpamPackage.Map.empty; opams; conf_files = OpamPackage.Name.Map.empty; packages = OpamPackage.Set.empty; sys_packages = lazy OpamPackage.Map.empty; available_packages = lazy OpamPackage.Set.empty; pinned = OpamPackage.Set.empty; installed = OpamPackage.Set.empty; installed_opams = OpamPackage.Map.empty; installed_roots = OpamPackage.Set.empty; reinstall = lazy OpamPackage.Set.empty; invalidated = lazy OpamPackage.Set.empty}
      in
      let open OpamTypes in
      let tmpdir = dirname_of_fpath tmpdir in
      OpamUpdate.download_package_source t pkg tmpdir @@+ function
      | Some (Not_available (_,s)), _ | _, (_, Not_available (_, s)) :: _ ->
          Progress.interject_with begin fun () ->
            print_endline (OpamPackage.to_string pkg^" failed to download: " ^ s)
          end;
          Done ()
      | None, _ | Some (Result _ | Up_to_date _), _ ->
        OpamAction.prepare_package_source t pkg tmpdir @@| function
        | None -> ()
        | Some e ->
            Progress.interject_with begin fun () ->
              print_endline (OpamPackage.to_string pkg^": "^Printexc.to_string e)
            end;
    in
    OpamProcess.Job.run job;
    result (Path.move tmpdir pkgdir)
  end;
  pkgdir

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

let search ~regexp =
  let () = OpamCoreConfig.update ~verbose_level:0 ~disp_status_line:`Never () in
  let dst = dst () in
  prerr_endline "[Info] Getting the list of all known opam packages..";
  let opams = sync ~dst in
  let pkgs = OpamPackage.Map.keys opams in
  let grep = get_grep_cmd () in
  prerr_endline ("[Info] Fetching and grepping using "^Cmd.get_line_tool grep^"..");
  Progress.with_reporter (bar ~total:(List.length pkgs)) begin fun progress ->
    List.iter begin fun pkg ->
      progress 1;
      let pkgdir = check ~opams ~dst pkg in
      match Exec.run (grep % "--binary" % "-qsr" % "-e" % regexp % Fpath.to_string pkgdir) with
      | Ok () ->
          Progress.interject_with begin fun () ->
            print_endline (OpamPackage.name_to_string pkg^" matches your regexp.")
          end
      | Error _ -> () (* Ignore errors here *)
    end pkgs;
  end

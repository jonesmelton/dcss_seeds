open! Core

module Version = struct
  type t = string [@@deriving compare, equal, sexp_of]

  let to_string t = t

  (* Version strings come from crawl.version() and reach us through a URL, so
     they are validated rather than trusted. *)
  let is_valid s =
    (not (String.is_empty s))
    && String.length s <= 64
    && String.for_all s ~f:(fun c ->
      Char.is_alphanum c || List.mem [ '.'; '-'; '_' ] c ~equal:Char.equal)
  ;;

  let of_string s =
    if is_valid s then Ok s else Or_error.errorf "not a version string: %S" s
  ;;

  (* Release order over the numeric prefix: released versions compare by
     their dotted numbers, and an unreleased build (trunk) is later than every
     release, since trunk carries changes no release has taken. [compare] is
     plain string order, which sorts "0.10.1" before "0.9.1" and is useless
     for asking "is this build old enough to have X". The first consumer is
     Search.Brand's per-version ego spelling; Rename wants the same order when
     it lands (docs/plans/crawl-renames.md). *)
  let release_numbers s =
    let n = String.length s in
    let rec numeric i =
      if i < n && (Char.is_digit s.[i] || Char.equal s.[i] '.')
      then numeric (i + 1)
      else i
    in
    let stop = numeric 0 in
    if stop = 0
    then None
    else (
      let parts = String.split (String.subo s ~pos:0 ~len:stop) ~on:'.' in
      match List.map parts ~f:Int.of_string_opt |> Option.all with
      | None -> None
      | Some numbers -> Some numbers)
  ;;

  let release_compare a b =
    match release_numbers a, release_numbers b with
    | Some na, Some nb -> List.compare Int.compare na nb
    | None, None -> String.compare a b
    | None, Some _ -> 1
    | Some _, None -> -1
  ;;

  (* A released build names a fixed compile. Trunk is effectively a new build a
     day, so the per-version facts the corpus stores once -- book contents, the
     temple god pool -- would silently describe whichever build was checked out.
     `make` still defaults V=trunk, which is about the dev loop. *)
  let is_released s =
    (not (String.is_empty s))
    && Char.is_digit s.[0]
    && String.exists s ~f:(Char.equal '.')
  ;;
end

module Seed = struct
  let max = "18446744073709551615"

  let of_string s =
    if String.is_empty s || not (String.for_all s ~f:Char.is_digit)
    then Or_error.error_string "a seed is a number"
    else if String.equal s "0"
    then Or_error.error_string "seed 0 names no game"
    else if Char.equal s.[0] '0'
    then Or_error.error_string "a seed is written without leading zeros"
    else if
      String.length s > String.length max
      || (String.length s = String.length max && String.( > ) s max)
    then Or_error.errorf "a seed is at most %s" max
    else Ok s
  ;;
end

module Page = struct
  type t =
    { after : string option
    ; limit : int
    }
  [@@deriving sexp_of]

  let default_limit = 50
  let max_limit = 200

  let create ?after ~limit () =
    { after; limit = Int.clamp_exn limit ~min:1 ~max:max_limit }
  ;;

  let first = { after = None; limit = default_limit }
end

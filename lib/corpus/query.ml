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

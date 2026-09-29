open! Core
module Served = Seed_web.Served

(* The sitemap and robots.txt are one policy stated twice, so the guard is that
   they cannot disagree: every URL the sitemap advertises must be a path
   robots.txt does not disallow. *)
let%expect_test "the sitemap advertises only crawlable paths" =
  let xml = Seed_web.sitemap_xml in
  let locs =
    String.substr_index_all xml ~may_overlap:false ~pattern:"<loc>"
    |> List.map ~f:(fun i ->
      let start = i + String.length "<loc>" in
      let stop =
        Option.value_exn (String.substr_index xml ~pos:start ~pattern:"</loc>")
      in
      String.sub xml ~pos:start ~len:(stop - start))
  in
  let disallowed path =
    List.exists [ "/seed/"; "/search"; "/jump" ] ~f:(fun pattern ->
      String.is_substring path ~substring:pattern
      (* /search/help is the descriptive page under a disallowed prefix; robots
         reads Disallow: /*/search as a prefix match. *)
      && not (String.is_suffix path ~suffix:"/search/help"))
  in
  List.iter locs ~f:(fun loc -> printf "%-52s disallowed: %b\n" loc (disallowed loc));
  [%expect
    {|
    https://dcss.garden/                                 disallowed: false
    https://dcss.garden/0.34.1/                          disallowed: false
    https://dcss.garden/0.34.1/about                     disallowed: false
    https://dcss.garden/0.33.1/                          disallowed: false
    https://dcss.garden/0.33.1/about                     disallowed: false
    https://dcss.garden/0.32.1/                          disallowed: false
    https://dcss.garden/0.32.1/about                     disallowed: false
    |}]
;;

(* Adding a build must extend the sitemap without anyone remembering to, which
   is why it is derived from [Served.all]. A build in the picker and absent from
   the sitemap is invisible to search engines and looks identical to one that
   was never added. *)
let%expect_test "every served build appears in the sitemap" =
  let xml = Seed_web.sitemap_xml in
  List.iter Served.all ~f:(fun t ->
    let v = Served.to_string t in
    printf
      "%-10s listing: %b  about: %b\n"
      v
      (String.is_substring
         xml
         ~substring:(sprintf "<loc>https://dcss.garden/%s/</loc>" v))
      (String.is_substring
         xml
         ~substring:(sprintf "<loc>https://dcss.garden/%s/about</loc>" v)));
  [%expect
    {|
    0.34.1     listing: true  about: true
    0.33.1     listing: true  about: true
    0.32.1     listing: true  about: true
    |}]
;;

(* The seed space is unbounded and the sitemap is a fixed document, so no seed
   may ever appear in it. *)
let%expect_test "no seed URLs in the sitemap" =
  let xml = Seed_web.sitemap_xml in
  printf "mentions /seed/: %b\n" (String.is_substring xml ~substring:"/seed/");
  printf
    "loc count: %d\n"
    (List.length (String.substr_index_all xml ~may_overlap:false ~pattern:"<loc>"));
  [%expect
    {|
    mentions /seed/: false
    loc count: 7
    |}]
;;

(* robots.txt must point at the sitemap, since that is the only way a crawler
   that was not told the URL finds it. *)
let%expect_test "robots.txt advertises the sitemap" =
  printf "%s" Seed_web.robots_txt;
  [%expect
    {|
    User-agent: *
    Disallow: /*/seed/
    Disallow: /*/search
    Disallow: /*/jump
    Crawl-delay: 10

    Sitemap: https://dcss.garden/sitemap.xml
    |}]
;;

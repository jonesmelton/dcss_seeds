open! Core
module Db = Seed_corpus.Db

(* Query-plan wording and float-to-text rendering are sqlite's, and they change
   between versions; the expects elsewhere in this suite were written against
   the pinned build (tools/provision-sqlite). A failure here means the bindings
   link some other sqlite -- rebuild them before trusting any other diff. *)
let%expect_test "sqlite is the pinned build" =
  let db = Test_search.fresh_db () in
  Db.query db "select sqlite_version()" |> List.iter ~f:print_endline;
  [%expect {| 3.53.4 |}];
  Db.close db
;;

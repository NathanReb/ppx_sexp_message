open StdLabels
open Ppx_core.Std
open Asttypes
open Parsetree
open Ast_builder.Default

[@@@metaloc loc];;

let sexp_atom ~loc x = [%expr Sexplib.Sexp.Atom [%e x]]
let sexp_list ~loc x = [%expr Sexplib.Sexp.List [%e x]]

let sexp_inline ~loc l =
  match l with
  | [x] -> x
  | _   -> sexp_list ~loc (elist ~loc l)
;;

(* Same as Ppx_sexp_value.omittable_sexp *)
type omittable_sexp =
  | Present of expression
  | Optional of Location.t * expression * (expression -> expression)
  | Absent

let wrap_sexp_if_present omittable_sexp ~f =
  match omittable_sexp with
  | Optional (loc, e, k) -> Optional (loc, e, (fun e -> f (k e)))
  | Present e -> Present (f e)
  | Absent -> Absent

let sexp_of_constraint ~loc expr ctyp =
  match ctyp with
  | [%type: [%t? ty] sexp_option] ->
    let sexp_of = Ppx_sexp_conv_expander.Sexp_of.core_type ty in
    Optional (loc, expr, fun expr -> eapply ~loc sexp_of [expr])
  | _ ->
    let sexp_of = Ppx_sexp_conv_expander.Sexp_of.core_type ctyp in
    Present (eapply ~loc sexp_of [expr])
;;

let sexp_of_constant ~loc const =
  let f typ =
    eapply ~loc (evar ~loc ("Sexplib.Conv.sexp_of_" ^ typ)) [pexp_constant ~loc const]
  in
  match const with
  | Const_int       _ -> f "int"
  | Const_char      _ -> f "char"
  | Const_string    _ -> f "string"
  | Const_float     _ -> f "float"
  | Const_int32     _ -> f "int32"
  | Const_int64     _ -> f "int64"
  | Const_nativeint _ -> f "nativeint"
;;

let rewrite_here e =
  match e.pexp_desc with
  | Pexp_extension ({ txt = "here"; _ }, PStr []) ->
    Ppx_here_expander.lift_position_as_string ~loc:e.pexp_loc
  | _ -> e
;;

let sexp_of_expr e =
  let e = rewrite_here e in
  let loc = e.pexp_loc in
  match e.pexp_desc with
  | Pexp_constant (Const_string ("", _)) ->
    Absent
  | Pexp_constant const ->
    Present (sexp_of_constant ~loc const)
  | Pexp_constraint (expr, ctyp) ->
    sexp_of_constraint ~loc expr ctyp
  | _ -> Present [%expr Sexplib.Conv.sexp_of_string [%e e]]
;;

type arg_label =
  | Nolabel
  | Labelled of string
  | Optional

(* Will help with the switch to 4.03 *)
let arg_label_of_string = function
  | "" -> Nolabel
  | s when s.[0] = '?' -> Optional
  | s -> Labelled s
;;

let sexp_of_labelled_expr (label, e) =
  let loc = e.pexp_loc in
  match label, e.pexp_desc with
  | Nolabel, Pexp_constraint (expr, _) ->
    let expr_str = Pprintast.string_of_expression expr in
    let k e = sexp_inline ~loc [sexp_atom ~loc (estring ~loc expr_str); e] in
    wrap_sexp_if_present (sexp_of_expr e) ~f:k
  | Nolabel, _ ->
    sexp_of_expr e
  | Labelled "_", _ ->
    sexp_of_expr e
  | Labelled label, _ ->
    let k e =
      sexp_inline ~loc [sexp_atom ~loc (estring ~loc label); e]
    in
    wrap_sexp_if_present (sexp_of_expr e) ~f:k
  | Optional, _ ->
    (* Could be used to encode sexp_option if that's ever needed. *)
    Location.raise_errorf ~loc
      "ppx_sexp_value: optional argument not allowed here"
;;

let sexp_of_labelled_exprs ~loc labels_and_exprs =
  let l = List.map labels_and_exprs ~f:sexp_of_labelled_expr in
  let res =
    List.fold_left (List.rev l) ~init:(elist ~loc []) ~f:(fun acc e ->
      match e with
      | Absent -> acc
      | Present e -> [%expr [%e e] :: [%e acc] ]
      | Optional (_, v_opt, k) ->
        (* We match simultaneously on the head and tail in the generated code to avoid
           changing their respective typing environments. *)
        [%expr
          match [%e v_opt], [%e acc] with
          | None, tl -> tl
          | Some v, tl -> [%e k [%expr v]] :: tl
        ])
  in
  let has_optional_values =
    List.exists l ~f:(function (Optional _ : omittable_sexp) -> true | _ -> false)
  in
  (* The two branches do the same thing, but when there are no optional values, we can do
     it at compile-time, which avoids making the generated code ugly. *)
  if has_optional_values
  then
    [%expr
      match [%e res] with
      | [h] -> h
      | [] | _ :: _ :: _ as res -> [%e sexp_list ~loc [%expr res]]
    ]
  else
    match res with
    | [%expr [ [%e? h] ] ] -> h
    | _ -> sexp_list ~loc res
;;

let expand ~loc ~path:_ = function
  | None ->
    sexp_list ~loc (elist ~loc [])
  | Some e ->
    let loc = e.pexp_loc in
    let labelled_exprs =
      match e.pexp_desc with
      | Pexp_apply (f, args) ->
        (Nolabel, f) :: List.map args ~f:(fun (label, e) -> arg_label_of_string label, e)
      | _ ->
        (Nolabel, e) :: []
    in
    sexp_of_labelled_exprs ~loc labelled_exprs
;;

let message =
  Extension.declare "message" Extension.Context.expression
    Ast_pattern.(map (single_expr_payload __) ~f:(fun f x -> f (Some x)) |||
                 map (pstr nil              ) ~f:(fun f   -> f None))
    expand
;;

let () =
  Ppx_driver.register_transformation "sexp_message"
    ~extensions:[ message ]
;;

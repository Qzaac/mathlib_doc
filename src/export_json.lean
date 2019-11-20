/-
Copyright (c) 2019 Robert Y. Lewis. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Robert Y. Lewis
-/

import tactic.core system.io data.string.defs tactic.interactive data.list.sort
import all

/-!
Used to generate a json file for html docs.

The json file is a list of maps, where each map has the structure
{ name: string,
  args : list string,
  type: string,
  doc_string: string,
  filename: string,
  line: int,
  attributes: list string,
  kind: string,
  structure_fields: list (list string),
  constructors: list (list string) }

The lists in structure_fields and constructors are assumed to contain two strings each.

Include this file somewhere in mathlib, e.g. in the `scripts` directory. Make sure mathlib is
precompiled, with `all.lean` generated by `mk_all.sh`.

Usage: `lean --run export_json.lean` creates `json_export.txt` in the current directory.
-/

open tactic io io.fs

/-- The information collected from each declaration -/
structure decl_info :=
(name : name)
(args : list string)
(type : string)
(doc_string : option string)
(filename : string)
(line : ℕ)
(attributes : list string) -- not all attributes, we have a hardcoded list to check
(kind : string) -- def, thm, cnst, ax
(structure_fields : list (string × string)) -- name and type of fields of a constructor
(constructors : list (string × string)) -- name and type of constructors of an inductive type

structure module_doc_info :=
(filename : string)
(line : ℕ)
(content : string)

meta def escape_quotes (s : string) : string :=
s.fold "" (λ s x, s ++ if x = '"' then '\\'.to_string ++ '"'.to_string else x.to_string)

meta def decl_info.to_format : decl_info → format
| ⟨name, args, type, doc_string, filename, line, attributes, kind, structure_fields, constructors⟩ :=
let doc_string := doc_string.get_or_else "",
    args := args.map repr,
    attributes := attributes.map repr,
    structure_fields := structure_fields.map (λ ⟨n, t⟩, format!"[\"{to_string n}\", {repr t}]"),
    constructors := constructors.map (λ ⟨n, t⟩, format!"[\"{to_string n}\", {repr t}]") in
"{" ++ format!"\"name\":\"{to_string name}\", \"args\":{args}, \"type\":{repr type}, \"doc_string\":{repr doc_string}, "
    ++ format!"\"filename\":\"{filename}\",\"line\":{line}, \"attributes\":{attributes}, "
    ++ format!" \"kind\":{repr kind}, \"structure_fields\":{structure_fields}, \"constructors\":{constructors}" ++ "}"

section

open tactic.interactive

private meta def format_binders : list name × binder_info × expr → tactic format
| (ns, binder_info.default, t) := pformat!"({format_names ns} : {t})"
| (ns, binder_info.implicit, t) := pformat!"{{{format_names ns} : {t}}"
| (ns, binder_info.strict_implicit, t) := pformat!"⦃{format_names ns} : {t}⦄"
| ([n], binder_info.inst_implicit, t) :=
  if "_".is_prefix_of n.to_string
    then pformat!"[{t}]"
    else pformat!"[{format_names [n]} : {t}]"
| (ns, binder_info.inst_implicit, t) := pformat!"[{format_names ns} : {t}]"
| (ns, binder_info.aux_decl, t) := pformat!"({format_names ns} : {t})"

meta def get_args_and_type (e : expr) : tactic (list string × string) :=
prod.fst <$> solve_aux e (
do intros,
   cxt ← local_context >>= tactic.interactive.compact_decl,
   cxt' ← cxt.mmap $ λ t, to_string <$> format_binders t,
   tgt ← target >>= pp,
   return (cxt', to_string tgt))

end

/-- The attributes we check for -/
meta def attribute_list := [`simp, `squash_cast, `move_cast, `elim_cast, `nolint, `ext, `instance]

meta def attributes_of (n : name) : tactic (list string) :=
list.map to_string <$> attribute_list.mfilter (λ attr, succeeds $ has_attribute attr n)

meta def declaration.kind : declaration → string
| (declaration.defn a a_1 a_2 a_3 a_4 a_5) := "def"
| (declaration.thm a a_1 a_2 a_3) := "thm"
| (declaration.cnst a a_1 a_2 a_3) := "cnst"
| (declaration.ax a a_1 a_2) := "ax"

-- does this not exist already? I'm confused.
meta def expr.instantiate_pis : list expr → expr → expr
| (e'::es) (expr.pi n bi t e) := expr.instantiate_pis es (e.instantiate_var e')
| _        e              := e

-- assumes proj_name exists
meta def get_proj_type (struct_name proj_name : name) : tactic string :=
do (locs, _) ← mk_const struct_name >>= infer_type >>= mk_local_pis,
   proj_tp ← mk_const proj_name >>= infer_type,
   (_, t) ← mk_local_pisn (proj_tp.instantiate_pis locs) 1,
   to_string <$> pp t

meta def mk_structure_fields (decl : name) (e : environment) : tactic (list (string × string)) :=
match e.is_structure decl, e.get_projections decl with
| tt, some proj_names := proj_names.mmap $
    λ n, do tp ← get_proj_type decl n, return (to_string n, to_string tp)
| _, _ := return []
end

-- this is used as a hack in get_constructor_type to avoid printing `Type ?`.
meta def mk_const_with_params (d : declaration) : expr :=
let lvls := d.univ_params.map level.param in
expr.const d.to_name lvls

meta def get_constructor_type (type_name constructor_name : name) : tactic string :=
do d ← get_decl type_name,
   (locs, _) ← infer_type (mk_const_with_params d) >>= mk_local_pis,
   proj_tp ← mk_const constructor_name >>= infer_type,
   do t ← pis locs (proj_tp.instantiate_pis locs), --.abstract_locals (locs.map expr.local_uniq_name),
   to_string <$> pp t

meta def mk_constructors (decl : name) (e : environment): tactic (list (string × string)) :=
if (¬ e.is_inductive decl) ∨ (e.is_structure decl) then return [] else
do d ← get_decl decl, ns ← get_constructors_for (mk_const_with_params d),
   ns.mmap $ λ n, do tp ← get_constructor_type decl n, return (to_string n, to_string tp)

/-- extracts `decl_info` from `d`. Should return `none` instead of failing. -/
meta def process_decl (d : declaration) : tactic (option decl_info) :=
do ff ← d.in_current_file | return none,
   e ← get_env,
   let decl_name := d.to_name,
   if decl_name.is_internal ∨ d.is_auto_generated e then return none else do
   some filename ← return (e.decl_olean decl_name) | return none,
   some ⟨line, _⟩ ← return (e.decl_pos decl_name) | return none,
   doc_string ← (some <$> doc_string decl_name) <|> return none,
   (args, type) ← get_args_and_type d.type,
--   type ← escape_quotes <$> to_string <$> pp d.type,
   attributes ← attributes_of decl_name,
   structure_fields ← mk_structure_fields decl_name e,
   constructors ← mk_constructors decl_name e,
   return $ some ⟨decl_name, args, type, doc_string, filename, line, attributes, d.kind, structure_fields, constructors⟩

meta def run_on_dcl_list (e : environment) (ens : list name) (handle : handle) (is_first : bool) : io unit :=
ens.mfoldl  (λ is_first d_name, do
     d ← run_tactic (e.get d_name),
     odi ← run_tactic (process_decl d),
     match odi with
     | some di := do
        when (bnot is_first) (put_str_ln handle ","),
        put_str_ln handle $ to_string di.to_format,
        return ff
     | none := return is_first
     end) is_first >> return ()

meta def itersplit {α} : list α → ℕ → list (list α)
| l 0 := [l]
| l 1 := let (l1, l2) := l.split in [l1, l2]
| l (k+2) := let (l1, l2) := l.split in itersplit l1 (k+1) ++ itersplit l2 (k+1)

meta def write_module_doc_pair : pos × string → string
| (⟨line, _⟩, doc) := "{\"line\":" ++ to_string line ++ ", \"doc\" :" ++ repr doc ++ "}"

meta def write_olean_docs : tactic (list string) :=
do docs ← olean_doc_strings,
   return (docs.foldl (λ rest p, match p with
   | (none, _) := rest
   | (_, []) := rest
   | (some filename, l) :=
     let new := "\"" ++ filename ++ "\":" ++ to_string (l.map write_module_doc_pair)  in
     new::rest
   end) [])

/-- Using `environment.mfold` is much cleaner. Unfortunately this led to a segfault, I think because
of a stack overflow. Converting the environment to a list of declarations and folding over that led
to "deep recursion detected". Instead, we split that list into 8 smaller lists and process them
one by one. More investigation is needed. -/
meta def export_json (filename : string) : io unit :=
do handle ← mk_file_handle filename mode.write,
   put_str_ln handle "{ \"decls\":[",
   e ← run_tactic get_env,
   let ens := environment.get_decl_names e,
   let enss := itersplit ens 3,
   enss.mfoldl (λ is_first l, do run_on_dcl_list e l handle is_first, return ff) tt,
   put_str_ln handle "],",
   ods ← run_tactic write_olean_docs,
   put_str_ln handle $ "\"mod_docs\": {" ++ string.join (ods.intersperse ",\n") ++ "}}",
   close handle

meta def main : io unit :=
export_json "json_export.txt"
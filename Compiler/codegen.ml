(* ===----------------------------------------------------------------------===
 * Code Generation
 *===----------------------------------------------------------------------===*)

open Llvm
open Ast
open Sast
open Analyzer
open Exceptions
open Batteries

exception Error of string

let context = global_context ()
let the_module = create_module context "Dice Codegen"
let builder = builder context
let named_values:(string, llvalue) Hashtbl.t = Hashtbl.create 10

let i32_t = i32_type context;;
let i8_t = i8_type context;;
let f_t = double_type context;;
let i1_t = i1_type context;;

(* Need to add logic for fmul and fdiv *)
let rec handle_binop e1 op e2 llbuilder = 
	let e1 = codegen_sexpr llbuilder e1 in
	let e2 = codegen_sexpr llbuilder e2 in
	match op with
			Add 		-> build_add e1 e2 "addtmp" llbuilder
	| 	Sub 		-> build_sub e1 e2 "subtmp" llbuilder
	| 	Mult 		-> build_mul e1 e2 "multmp" llbuilder
	| 	Div 		-> build_fdiv e1 e2 "divtmp" llbuilder
	| 	Equal 	-> build_icmp Icmp.Eq e1 e2 "eqtmp" llbuilder
	| 	Neq 		-> build_icmp Icmp.Ne e1 e2 "neqtmp" llbuilder
	| 	Less 		-> build_icmp Icmp.Slt e1 e2 "lesstmp" llbuilder
	| 	Leq 		-> build_icmp Icmp.Sle e1 e2 "leqtmp" llbuilder
	| 	Greater -> build_icmp Icmp.Sgt e1 e2 "sgttmp" llbuilder
	| 	Geq 		-> build_icmp Icmp.Sge e1 e2 "sgetmp" llbuilder
	| 	And 		-> build_and e1 e2 "andtmp" llbuilder
	| 	Or 			-> build_or  e1 e2 "ortmp" llbuilder
	| 	_ 			-> raise Exceptions.InvalidBinaryOperator

and codegen_print llbuilder el = 
	let printf_ty = var_arg_function_type i32_t [| pointer_type i8_t |] in
	let printf = declare_function "printf" printf_ty the_module in

	let params = List.map (codegen_sexpr llbuilder) el in
	let param_types = List.map (Analyzer.get_type_from_sexpr) el in 
	let map_param_to_string = function 
			Arraytype(Char_t, 1) 	-> "%s"
		| 	Datatype(Int_t) 		-> "%d"
		| 	Datatype(Float_t) 	-> "%f"
		| 	Datatype(Bool_t) 		-> "%d"
		| 	Datatype(Char_t) 		-> "%c"
		| 	_ 									-> raise (Exceptions.InvalidTypePassedToPrintf)
	in 
	let const_str = List.fold_left (fun s t -> s ^ map_param_to_string t) "" param_types in
	let s = codegen_sexpr llbuilder (SString_Lit(const_str, Arraytype(Char_t, 1))) in
	let zero = const_int i32_t 0 in 
	let s = build_in_bounds_gep s [| zero |] "" llbuilder in
	build_call printf (Array.of_list (s :: params)) "" llbuilder

and codegen_sexpr llbuilder = function
			SInt_Lit(i, d)            -> const_int i32_t i
	|   SBoolean_Lit(b, d)        -> if b then const_int i1_t 1 else const_int i1_t 0
	|   SFloat_Lit(f, d)          -> const_float f_t f 
	|   SString_Lit(s, d)         -> build_global_stringptr s "" llbuilder
	|   SChar_Lit(c, d)           -> const_int i32_t (Char.code c)
	|   SId(id, d)                -> build_global_stringptr "Hi" "" llbuilder
	|   SBinop(e1, op, e2, d)     -> handle_binop e1 op e2 llbuilder
	|   SAssign(e1, e2, d)        -> build_global_stringptr "Hi" "" llbuilder
	|   SNoexpr d                 -> build_add (const_int i32_t 0) (const_int i32_t 0) "nop" llbuilder
	|   SArrayCreate(t, el, d)    -> build_global_stringptr "Hi" "" llbuilder
	|   SArrayAccess(e, el, d)    -> build_global_stringptr "Hi" "" llbuilder
	|   SObjAccess(e1, e2, d)     -> build_global_stringptr "Hi" "" llbuilder
	|   SCall(fname, el, d)       ->  (function
																				"print" -> codegen_print llbuilder el
																			| _ -> build_global_stringptr "Hi" "" llbuilder) fname
	|   SObjectCreate(id, el, d)  -> build_global_stringptr "Hi" "" llbuilder
	|   SArrayPrimitive(el, d)    -> build_global_stringptr "Hi" "" llbuilder
	|   SUnop(op, e, d)           -> build_global_stringptr "Hi" "" llbuilder
	|   SNull d                   -> build_global_stringptr "Hi" "" llbuilder

let rec codegen_if_stmt exp then_ (else_:Sast.sstmt) llbuilder =
	let cond_val = codegen_sexpr llbuilder exp in

	(* Grab the first block so that we might later add the conditional branch
	 * to it at the end of the function. *)
	let start_bb = insertion_block llbuilder in
	let the_function = block_parent start_bb in

	let then_bb = append_block context "then" the_function in

	(* Emit 'then' value. *)
	position_at_end then_bb llbuilder;
	let then_val = codegen_stmt llbuilder then_ in

	(* Codegen of 'then' can change the current block, update then_bb for the
	 * phi. We create a new name because one is used for the phi node, and the
	 * other is used for the conditional branch. *)
	let new_then_bb = insertion_block llbuilder in

	(* Emit 'else' value. *)
	let else_bb = append_block context "else" the_function in
	position_at_end else_bb llbuilder;
	let else_val = codegen_stmt llbuilder else_ in

	(* Codegen of 'else' can change the current block, update else_bb for the
	 * phi. *)
	let new_else_bb = insertion_block llbuilder in

	(* Emit merge block. *)
	let merge_bb = append_block context "ifcont" the_function in
	position_at_end merge_bb llbuilder;
	let incoming = [(then_val, new_then_bb); (else_val, new_else_bb)] in
	let phi = build_phi incoming "iftmp" llbuilder in

	(* Return to the start block to add the conditional branch. *)
	position_at_end start_bb llbuilder;
	ignore (build_cond_br cond_val then_bb else_bb llbuilder);

	(* Set a unconditional branch at the end of the 'then' block and the
	 * 'else' block to the 'merge' block. *)
	position_at_end new_then_bb llbuilder; ignore (build_br merge_bb llbuilder);
	position_at_end new_else_bb llbuilder; ignore (build_br merge_bb llbuilder);

	(* Finally, set the builder to the end of the merge block. *)
	position_at_end merge_bb llbuilder;

	phi

and codegen_stmt llbuilder = function
			SBlock sl        			-> List.hd(List.map (codegen_stmt llbuilder) sl)

	|   SExpr(e, d)          	-> codegen_sexpr llbuilder e
	|   SReturn(e, d)    			-> build_ret (codegen_sexpr llbuilder e) llbuilder
	|   SIf (e, s1, s2)       -> codegen_if_stmt e s1 s2 llbuilder
	|   SFor (e1, e2, e3 ,s)  -> build_global_stringptr "Hi" "" llbuilder
	|   SWhile (e, s)    			-> build_global_stringptr "Hi" "" llbuilder
	|   SBreak           			-> build_global_stringptr "Hi" "" llbuilder   
	|   SContinue        			-> build_global_stringptr "Hi" "" llbuilder
	|   SLocal(d, s, e)  			-> build_global_stringptr "Hi" "" llbuilder

let codegen_func fdecl = 
		let handle_func = function
			_ -> build_global_stringptr "Hi" "" builder 
		in 
		handle_func fdecl.sfname

let codegen_library_functions = ()

let codegen_struct s =
	named_struct_type context s.scname

let codegen_main main = 
	let fty = function_type i32_t [| |] in
	let f = define_function "main" fty the_module in
	let llbuilder = builder_at_end context (entry_block f) in
	let _ = codegen_stmt llbuilder (SBlock (main.sbody)) in
	build_ret (const_int i32_t 0) llbuilder 

let codegen_sprogram sprogram = 
	let _ = codegen_library_functions in
	(* let _ = List.map (fun f -> codegen_func f) sprogram.functions in *)
	let _ = List.map (fun s -> codegen_struct s) sprogram.classes in
	let _ = codegen_main sprogram.main in
		the_module
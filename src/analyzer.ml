open Sast
open Ast
open Processor
open Utils
open Filepath
open Conf

module StringMap = Map.Make (String)

module SS = Set.Make(
    struct
        let compare = Pervasives.compare
        type t = datatype
    end )

type class_map = {
		field_map       : Ast.field StringMap.t;
		func_map        : Ast.func_decl StringMap.t;
		constructor_map : Ast.func_decl StringMap.t;
		reserved_map 	: sfunc_decl StringMap.t;
}

type env = {
		env_class_maps: class_map StringMap.t;
		env_name      : string;
		env_cmap 	  : class_map;
		env_locals    : datatype StringMap.t;
		env_parameters: Ast.formal StringMap.t;
		env_returnType: datatype;
		env_callStack : bool;
		env_reserved  : sfunc_decl list;
}

let construct_env cmaps cname cmap locals parameters returnType callStack reserved = 
{
	env_class_maps = cmaps;
	env_name       = cname;
	env_cmap 	   = cmap;
	env_locals     = locals;
	env_parameters = parameters;
	env_returnType = returnType;
	env_callStack  = callStack;
	env_reserved   = reserved;
}

let process_includes filename includes classes =
	(* Bring in each include  *)
	let processInclude include_statement = 
		let file_in = open_in include_statement in
		let lexbuf = Lexing.from_channel file_in in
		let token_list = Processor.build_token_list lexbuf in
		let program = Processor.parser include_statement token_list in
		ignore(close_in file_in);
		program
	in
	let rec iterate_includes classes m = function
			[] -> classes
		| (Include h) :: t -> 
			let h = if h = "stdlib" then Conf.stdlib_path else h in
			(* Check each include against the map *)
			let realpath = Filepath.realpath h in
			if StringMap.mem realpath m then 
				iterate_includes (classes) (m) (t)
			else 
				let result = processInclude realpath in 
				match result with Program(i,c) ->
				List.iter (fun x -> print_string(Utils.string_of_include x)) i;
				iterate_includes (classes @ c) (StringMap.add realpath 1 m) (i @ t)
	in
	iterate_includes classes (StringMap.add (Filepath.realpath filename) 1 StringMap.empty) includes

let get_name cname fdecl = 
	(* We use '.' to separate types so llvm will recognize the function name and it won't conflict *)
	let params = List.fold_left (fun s -> (function Formal(t, _) -> s ^ "." ^ Utils.string_of_datatype t | _ -> "" )) "" fdecl.formals in
	let name = Utils.string_of_fname fdecl.fname in
	if name = "main" 
		then "main"
		else cname ^ "." ^ name ^ params

(* Generate list of all classes to be used for semantic checking *)
let build_class_maps reserved cdecls =
		let reserved_map = List.fold_left (fun m f -> StringMap.add (Utils.string_of_fname f.sfname) f m) StringMap.empty reserved in
		(* helper global_obj cdecls *)
		let helper m (cdecl:Ast.class_decl) =  
			let fieldfun = (fun m -> (function Field(s, d, n) -> if (StringMap.mem (n) m) then raise(Exceptions.DuplicateField) else (StringMap.add n (Field(s, d, n)) m))) in
			let funcname = get_name cdecl.cname in
			let funcfun = 
				(fun m fdecl -> 
					if (StringMap.mem (funcname fdecl) m) 
						then raise(Exceptions.DuplicateFunction(funcname fdecl)) 
					else if (StringMap.mem (Utils.string_of_fname fdecl.fname) reserved_map)
						then raise(Exceptions.CannotUseReservedFuncName(Utils.string_of_fname fdecl.fname))
					else (StringMap.add (funcname fdecl) fdecl m)) 
			in
			let constructor_name = get_name cdecl.cname in
			let constructorfun = (fun m fdecl -> 
									if StringMap.mem (constructor_name fdecl) m 
										then raise(Exceptions.DuplicateConstructor) 
										else (StringMap.add (constructor_name fdecl) fdecl m)) 
			in
			(if (StringMap.mem cdecl.cname m) then raise (Exceptions.DuplicateClassName(cdecl.cname)) else
				StringMap.add cdecl.cname 
						{ field_map = List.fold_left fieldfun StringMap.empty cdecl.cbody.fields; 
							func_map = List.fold_left funcfun StringMap.empty cdecl.cbody.methods;
							constructor_map = List.fold_left constructorfun StringMap.empty cdecl.cbody.constructors; 
							reserved_map = reserved_map; } 
											 m) in
		List.fold_left helper StringMap.empty cdecls

let get_equality_binop_type type1 type2 se1 se2 op = 
        (* Equality op not supported for float operands. The correct way to test floats 
           for equality is to check the difference between the operands in question *)
	    if (type1 = Datatype(Float_t) || type2 = Datatype(Float_t)) then raise (Exceptions.InvalidBinopExpression "Equality operation is not supported for Float types")
        else 
        match type1, type2 with
        	Datatype(Char_t), Datatype(Int_t) 
        | 	Datatype(Int_t), Datatype(Char_t)
       	| 	Datatype(Objecttype(_)), Datatype(Null_t)
       	| 	Datatype(Null_t), Datatype(Objecttype(_))
       	| 	Datatype(Null_t), Arraytype(_, _)
       	| 	Arraytype(_, _), Datatype(Null_t) -> SBinop(se1, op, se2, Datatype(Bool_t))
       	| _ ->
       		if type1 = type2 then SBinop(se1, op, se2, Datatype(Bool_t))
       		else raise (Exceptions.InvalidBinopExpression "Equality operator can't operate on different types, with the exception of Int_t and Char_t")


let get_logical_binop_type se1 se2 op = function 
        (Datatype(Bool_t), Datatype(Bool_t)) -> SBinop(se1, op, se2, Datatype(Bool_t))
        | _ -> raise (Exceptions.InvalidBinopExpression "Logical operators only operate on Bool_t types")


let get_comparison_binop_type type1 type2 se1 se2 op =  
    let numerics = SS.of_list [Datatype(Int_t); Datatype(Char_t); Datatype(Float_t)]
    in
        if SS.mem type1 numerics && SS.mem type2 numerics
            then SBinop(se1, op, se2, Datatype(Bool_t))
        else raise (Exceptions.InvalidBinopExpression "Comparison operators operate on numeric types only")


let get_arithmetic_binop_type se1 se2 op = function 
        	(Datatype(Int_t), Datatype(Float_t)) 
        | 	(Datatype(Float_t), Datatype(Int_t)) 
        | 	(Datatype(Float_t), Datatype(Float_t)) 	-> SBinop(se1, op, se2, Datatype(Float_t))

        | 	(Datatype(Int_t), Datatype(Char_t)) 
        | 	(Datatype(Char_t), Datatype(Int_t)) 
        | 	(Datatype(Char_t), Datatype(Char_t)) 	-> SBinop(se1, op, se2, Datatype(Char_t))

        | 	(Datatype(Int_t), Datatype(Int_t)) 		-> SBinop(se1, op, se2, Datatype(Int_t))

        | _ -> raise (Exceptions.InvalidBinopExpression "Arithmetic operators don't support these types")

let rec get_ID_type env s = 
	try StringMap.find s env.env_locals
	with | Not_found -> 
	try let formal = StringMap.find s env.env_parameters in
		(function Formal(t, _) -> t | Many t -> t ) formal
	with | Not_found -> raise (Exceptions.UndefinedID s)

and check_array_primitive env el = 
	let rec iter t sel = function
		[] -> sel, t
	| 	e :: el -> 
		let se, _ = expr_to_sexpr env e in
		let se_t = get_type_from_sexpr se in
		if t = se_t 
			then iter t (se :: sel) el 
			else
				let t1 = Utils.string_of_datatype t in
				let t2 = Utils.string_of_datatype se_t in 
				raise(Exceptions.InvalidArrayPrimitiveConsecutiveTypes(t1, t2))
	in
	let se, _ = expr_to_sexpr env (List.hd el) in
	let el = List.tl el in
	let se_t = get_type_from_sexpr se in
	let sel, t = iter se_t ([se]) el in
	let se_t = match t with
					Datatype(x) -> Arraytype(x, 1)
				| 	Arraytype(x, n) -> Arraytype(x, n+1)
				| 	_ as t -> raise(Exceptions.InvalidArrayPrimitiveType(Utils.string_of_datatype t))
	in
	SArrayPrimitive(sel, se_t)

and check_array_init env d el = 
	(* Get dimension size for the array being created *)
	let array_complexity = List.length el in
	let check_elem_type e = 
		let sexpr, _ = expr_to_sexpr env e in
		let sexpr_type = get_type_from_sexpr sexpr in
		if sexpr_type = Datatype(Int_t) 
			then sexpr
			else raise(Exceptions.MustPassIntegerTypeToArrayCreate)
	in
	let convert_d_to_arraytype = function
		Datatype(x) -> Arraytype(x, array_complexity)
	| 	_ as t -> 
		let error_msg = Utils.string_of_datatype t in
		raise (Exceptions.ArrayInitTypeInvalid(error_msg))
	in
	let sexpr_type = convert_d_to_arraytype d in
	let sel = List.map check_elem_type el in
	SArrayCreate(d, sel, sexpr_type)

and check_array_access env e el = 
	(* Get dimensions of array, ex: foo[10][4][2] is dimen=3 *)
	let array_dimensions = List.length el in
	(* Check every e in el is of type Datatype(Int_t). Ensure all indices are ints *)
	let check_elem_type arg = 
		let sexpr, _ = expr_to_sexpr env arg in
		let sexpr_type = get_type_from_sexpr sexpr in
		if sexpr_type = Datatype(Int_t) 
			then sexpr
			else raise(Exceptions.MustPassIntegerTypeToArrayAccess)
	in
	(* converting e to se also checks if the array id has been declared  *)
	let se, _ = expr_to_sexpr env e in 
	let se_type = get_type_from_sexpr se in

	(* Check that e has enough dimens as e's in el. Return overall datatype of access*)
	let check_array_dim_vs_params num_params = function
		Arraytype(t, n) -> 
			if num_params < n then
				Arraytype(t, (n-num_params))
			else if num_params = n then
				Datatype(t)
			else
				raise (Exceptions.ArrayAccessInvalidParamLength(string_of_int num_params, string_of_int n))
	| 	_ as t -> 
		let error_msg = Utils.string_of_datatype t in
		raise (Exceptions.ArrayAccessExpressionNotArray(error_msg))
	in
	let sexpr_type = check_array_dim_vs_params array_dimensions se_type in
	let sel = List.map check_elem_type el in

	SArrayAccess(se, sel, sexpr_type)

and check_obj_access env lhs rhs = 
	let check_lhs = function
		This 			-> SId("this", Datatype(Objecttype(env.env_name)))
	|	Id s 			-> SId(s, get_ID_type env s)
	| 	_ as e 	-> raise (Exceptions.LHSofRootAccessMustBeIDorFunc (Utils.string_of_expr e))
	in
	let rec check_rhs env parent_type = 
		let ptype_name = match parent_type with
			Datatype(Objecttype(name)) 	-> name
		| 	_ as d						-> raise (Exceptions.ObjAccessMustHaveObjectType (Utils.string_of_datatype d))
		in 
		let get_id_type_from_object env id cname = 
			let cmap = StringMap.find cname env.env_class_maps in
			try (function Field(_, d, _) -> d) (StringMap.find id cmap.field_map)
			with | Not_found -> raise (Exceptions.UnknownIdentifierForClass(id, cname))
		in
		function
			(* Check fields in parent *)
			Id s 				-> SId(s, get_id_type_from_object env s ptype_name), env
			(* Check functions in parent *)
		| 	Call(fname, el) 	-> 
				let env = construct_env env.env_class_maps ptype_name env.env_cmap env.env_locals env.env_parameters env.env_returnType env.env_callStack env.env_reserved in
				check_call_type true env fname el, env
			(* Set parent, check if base is field *)
		| 	ObjAccess(e1, e2) 	-> 
				let old_env = env in
				let lhs, env = check_rhs env parent_type e1 in
				let lhs_type = get_type_from_sexpr lhs in
				let rhs, env = check_rhs env lhs_type e2 in
				let rhs_type = get_type_from_sexpr rhs in
				SObjAccess(lhs, rhs, rhs_type), old_env
		| 	_ as e				-> raise (Exceptions.InvalidAccessLHS (Utils.string_of_expr e))
	in 
	let arr_lhs, _ = expr_to_sexpr env lhs in
	let arr_lhs_type = get_type_from_sexpr arr_lhs in
	match arr_lhs_type with
		Arraytype(Char_t, 1) -> raise(Exceptions.CannotAccessLengthOfCharArray)
	|	Arraytype(_, _) -> 
			let rhs = match rhs with
				Id("length") -> SId("length", Datatype(Int_t))
			| 	_ -> raise(Exceptions.CanOnlyAccessLengthOfArray)
			in
			SObjAccess(arr_lhs, rhs, Datatype(Int_t))
	| _ ->
		let lhs = check_lhs lhs in
		let lhs_type = get_type_from_sexpr lhs in 
		let rhs, _ = check_rhs env lhs_type rhs in
		let rhs_type = get_type_from_sexpr rhs in
		SObjAccess(lhs, rhs, rhs_type)

and check_call_type isObjAccess env fname el = 
	let sel, env = exprl_to_sexprl env el in
	(* check that 'env.env_name' is in the list of defined classes *)
	let cmap = 
		try StringMap.find env.env_name env.env_class_maps
		with | Not_found -> raise (Exceptions.UndefinedClass env.env_name)
	in
	(* get a list of the types of the actuals to match against defined function formals *)
	let params = List.fold_left (fun s e -> s ^ "." ^ (Utils.string_of_datatype (get_type_from_sexpr e))) "" sel in
	let sfname = env.env_name ^ "." ^ fname ^ params in
	let (fname, ftype, func_type) = 
		try (sfname, (StringMap.find sfname cmap.func_map).returnType, User)
		with | Not_found -> 
		if isObjAccess then raise (Exceptions.FunctionNotFound fname)
		else 
		try (fname, (StringMap.find fname cmap.reserved_map).sreturnType, Reserved)
		with | Not_found -> raise (Exceptions.FunctionNotFound fname)
	in
	(* Add a reference to the class in front of the function call *)
	(* Must properly handle the case where this is a reserved function *)
	let sel = if func_type = Sast.User then sel else sel in
	SCall(fname, sel, ftype)

and check_object_constructor env s el = 
	let sel, env = exprl_to_sexprl env el in
	(* check that 'env.env_name' is in the list of defined classes *)
	let cmap = 
		try StringMap.find s env.env_class_maps
		with | Not_found -> raise (Exceptions.UndefinedClass s)
	in
	(* get a list of the types of the actuals to match against defined function formals *)
	let params = List.fold_left (fun s e -> s ^ "." ^ (Utils.string_of_datatype (get_type_from_sexpr e))) "" sel in
	let constructor_name = s ^ "." ^ "constructor" ^ params in
	let _ = 
		try StringMap.find constructor_name cmap.constructor_map
		with | Not_found -> raise (Exceptions.ConstructorNotFound constructor_name)
	in
	let ftype = Datatype(Objecttype(s)) in
	(* Add a reference to the class in front of the function call *)
	(* Must properly handle the case where this is a reserved function *)
	SObjectCreate(constructor_name, sel, ftype)

and check_assign env e1 e2 = 
	let se1, env = expr_to_sexpr env e1 in
	let se2, env = expr_to_sexpr env e2 in
	let type1 = get_type_from_sexpr se1 in
	let type2 = get_type_from_sexpr se2 in 
	match (type1, se2) with
		Datatype(Objecttype(_)), SNull(Datatype(Null_t)) 
	| 	Arraytype(_, _), SNull(Datatype(Null_t)) -> SAssign(se1, se2, type1)
	|   _ -> 
	match type1, type2 with
		Datatype(Char_t), Datatype(Int_t)
	| 	Datatype(Int_t), Datatype(Char_t) -> SAssign(se1, se2, type1)
	| _ -> 
	if type1 = type2 
		then SAssign(se1, se2, type1)
		else raise (Exceptions.AssignmentTypeMismatch(Utils.string_of_datatype type1, Utils.string_of_datatype type2))

and check_unop env op e = 
	let check_num_unop t = function
			Sub 	-> t
		| 	_ 		-> raise(Exceptions.InvalidUnaryOperation)
	in 
	let check_bool_unop = function
			Not 	-> Datatype(Bool_t)
		| 	_ 		-> raise(Exceptions.InvalidUnaryOperation)
	in
	let se, env = expr_to_sexpr env e in
	let t = get_type_from_sexpr se in
	match t with 
		Datatype(Int_t) 	
	|	Datatype(Float_t) 	-> SUnop(op, se, check_num_unop t op)
	|  	Datatype(Bool_t) 	-> SUnop(op, se, check_bool_unop op)
	| 	_ -> raise(Exceptions.InvalidUnaryOperation)

and check_binop env e1 op e2 =
	let se1, env = expr_to_sexpr env e1 in
	let se2, env = expr_to_sexpr env e2 in
	let type1 = get_type_from_sexpr se1 in
	let type2 = get_type_from_sexpr se2 in
    match op with
    Equal | Neq -> get_equality_binop_type type1 type2 se1 se2 op
    | And | Or -> get_logical_binop_type se1 se2 op (type1, type2)
    | Less | Leq | Greater | Geq -> get_comparison_binop_type type1 type2 se1 se2 op
    | Add | Mult | Sub | Div | Mod -> get_arithmetic_binop_type se1 se2 op (type1, type2) 
    | _ -> raise (Exceptions.InvalidBinopExpression ((Utils.string_of_op op) ^ " is not a supported binary op"))

and check_delete env e = 
	let se, _ = expr_to_sexpr env e in
	let t = get_type_from_sexpr se in
	match t with
		Arraytype(_, _) | Datatype(Objecttype(_)) -> SDelete(se)
	| 	_ -> raise(Exceptions.CanOnlyDeleteObjectsOrArrays)

and expr_to_sexpr env = function
		Int_Lit i           -> SInt_Lit(i, Datatype(Int_t)), env
	|   Boolean_Lit b       -> SBoolean_Lit(b, Datatype(Bool_t)), env
	|   Float_Lit f         -> SFloat_Lit(f, Datatype(Float_t)), env
	|   String_Lit s        -> SString_Lit(s, Arraytype(Char_t, 1)), env
	|   Char_Lit c          -> SChar_Lit(c, Datatype(Char_t)), env
	|   This                -> SId("this", Datatype(Objecttype(env.env_name))), env
	|   Id s                -> SId(s, get_ID_type env s), env
	|   Null                -> SNull(Datatype(Null_t)), env
	|   Noexpr              -> SNoexpr(Datatype(Void_t)), env

	|   ObjAccess(e1, e2)   -> check_obj_access env e1 e2, env
	|   ObjectCreate(s, el) -> check_object_constructor env s el, env
	|   Call(s, el)         -> check_call_type false env s el, env

	|   ArrayCreate(d, el)  -> check_array_init env d el, env
	|   ArrayAccess(e, el)  -> check_array_access env e el, env
	|   ArrayPrimitive el   -> check_array_primitive env el, env

	|   Assign(e1, e2)      -> check_assign env e1 e2, env
	|   Unop(op, e)         -> check_unop env op e, env
	|   Binop(e1, op, e2)   -> check_binop env e1 op e2, env
	| 	Delete(e) 			-> check_delete env e, env


and get_type_from_sexpr = function
		SInt_Lit(_, d)			-> d
	| 	SBoolean_Lit(_, d)		-> d
	| 	SFloat_Lit(_, d)		-> d
	| 	SString_Lit(_, d) 		-> d
	| 	SChar_Lit(_, d) 		-> d
	| 	SId(_, d) 				-> d
	| 	SBinop(_, _, _, d) 		-> d
	| 	SAssign(_, _, d) 		-> d
	| 	SNoexpr d 				-> d
	| 	SArrayCreate(_, _, d)	-> d
	| 	SArrayAccess(_, _, d) 	-> d
	| 	SObjAccess(_, _, d)		-> d
	| 	SCall(_, _, d) 			-> d
	|   SObjectCreate(_, _, d) 	-> d
	| 	SArrayPrimitive(_, d)	-> d
	|  	SUnop(_, _, d) 			-> d
	| 	SNull d 				-> d
	| 	SDelete _ 				-> Datatype(Void_t)

and exprl_to_sexprl env el =
  let env_ref = ref(env) in
  let rec helper = function
      head::tail ->
        let a_head, env = expr_to_sexpr !env_ref head in
        env_ref := env;
        a_head::(helper tail)
    | [] -> []
  in (helper el), !env_ref

let rec local_handler d s e env = 
	if StringMap.mem s env.env_locals 
		then raise (Exceptions.DuplicateLocal s)
		else
			let se, env = expr_to_sexpr env e in
			let t = get_type_from_sexpr se in
(* TODO allow class Foo someObj = new Goo() if class Goo extends Foo *)
			if t = Datatype(Void_t) || t = Datatype(Null_t) || t = d 
				then
				let new_env = {
					env_class_maps = env.env_class_maps;
					env_name = env.env_name;
					env_cmap = env.env_cmap;
					env_locals = StringMap.add s d env.env_locals;
					env_parameters = env.env_parameters;
					env_returnType = env.env_returnType;
					env_callStack = env.env_callStack;
					env_reserved = env.env_reserved;
				} in 
(* if the user-defined type being declared is not in global classes map, it is an undefined class *)
				(match d with
					Datatype(Objecttype(x)) -> 
						(if not (StringMap.mem (Utils.string_of_object d) env.env_class_maps) 
							then raise (Exceptions.UndefinedClass (Utils.string_of_object d)) 
							else SLocal(d, s, se), new_env)
				| 	_ -> SLocal(d, s, se), new_env) 
			else 
				(let type1 = (Utils.string_of_datatype t) in
				let type2 = (Utils.string_of_datatype d) in
				let ex = Exceptions.LocalAssignTypeMismatch(type1, type2) in
				raise ex)

(* Update this function to return an env object *)
let rec convert_stmt_list_to_sstmt_list env stmt_list = 
	let rec helper env = function 
			Block [] 				-> SBlock([SExpr(SNoexpr(Datatype(Void_t)), Datatype(Void_t))]), env

		|	Block sl 				-> 	let sl, _ = convert_stmt_list_to_sstmt_list env sl in
										SBlock(sl), env

		| 	Expr e 					-> 	let se, env = expr_to_sexpr env e in
										let t = get_type_from_sexpr se in 
									   	SExpr(se, t), env

		| 	Return e 				-> 	let se, _ = expr_to_sexpr env e in
										let t = get_type_from_sexpr se in
										if t = env.env_returnType 
											then SReturn(se, t), env
											else raise Exceptions.ReturnTypeMismatch

		| 	If(e, s1, s2) 			-> 	let se, _ = expr_to_sexpr env e in
										let t = get_type_from_sexpr se in
										let ifbody, _ = helper env s1 in
										let elsebody, _ = helper env s2 in
										if t = Datatype(Bool_t) 
											then SIf(se, ifbody, elsebody), env
											else raise Exceptions.InvalidIfStatementType

		| 	For(e1, e2, e3, s)		-> 	let se1, _ = expr_to_sexpr env e1 in
										let se2, _ = expr_to_sexpr env e2 in
										let se3, _ = expr_to_sexpr env e3 in
										let forbody, _ = helper env s in
										let conditional = get_type_from_sexpr se2 in
										if (conditional = Datatype(Bool_t) || conditional = Datatype(Void_t))
											then SFor(se1, se2, se3, forbody), env
											else raise Exceptions.InvalidForStatementType

		| 	While(e, s)				->	let se, _ = expr_to_sexpr env e in
										let t = get_type_from_sexpr se in
										let sstmt, _ = helper env s in 
										if (t = Datatype(Bool_t) || t = Datatype(Void_t)) 
											then SWhile(se, sstmt), env
											else raise Exceptions.InvalidWhileStatementType

		|  	Break 					-> SBreak, env (* Need to check if in right context *)
		|   Continue 				-> SContinue, env (* Need to check if in right context *)
		|   Local(d, s, e) 			-> local_handler d s e env
	in
	let env_ref = ref(env) in
	let rec iter = function
	  head::tail ->
	    let a_head, env = helper !env_ref head in
	    env_ref := env;
	    a_head::(iter tail)
	| [] -> []
	in 
	let sstmt_list = (iter stmt_list), !env_ref in
	sstmt_list

let append_code_to_constructor fbody cname ret_type = 
	let init_this = [SLocal(
		ret_type,
		"this",
		SCall(	"cast", 
				[SCall("malloc", 
					[	
						SCall("sizeof", [SNoexpr(ret_type)], Datatype(Int_t))
					], 
					Arraytype(Char_t, 1))
				],
				ret_type
			)
		)
	]
	in
	let ret_this = 
		[
			SReturn(
				SId("this", ret_type),
				ret_type
			)
		]
	in
	(* Need to check for duplicate default constructs *)
	(* Also need to add malloc around other constructors *)
	init_this @ fbody @ ret_this

let default_constructor_body cname = 
	let ret_type = Datatype(Objecttype(cname)) in
	let fbody = [] in
	append_code_to_constructor fbody cname ret_type

let append_code_to_main fbody cname ret_type = 
	let init_this = [SLocal(
		ret_type,
		"this",
		SCall(	"cast", 
				[SCall("malloc", 
					[	
						SCall("sizeof", [SNoexpr(ret_type)], Datatype(Int_t))
					], 
					Arraytype(Char_t, 1))
				],
				ret_type
			)
		)
	]
	in 
	init_this @ fbody

let convert_constructor_to_sfdecl class_maps reserved class_map cname constructor = 
	let env = {
		env_class_maps 	= class_maps;
		env_name     	= cname;
		env_cmap 		= class_map;
		env_locals    	= StringMap.empty;
		env_parameters	= List.fold_left (fun m f -> match f with Formal(d, s) -> (StringMap.add s f m) | _ -> m) StringMap.empty constructor.formals;
		env_returnType	= Datatype(Objecttype(cname));
		env_callStack 	= false;
		env_reserved 	= reserved;
	} in 
	let fbody = fst (convert_stmt_list_to_sstmt_list env constructor.body) in
	{
		sfname 			= Ast.FName (get_name cname constructor);
		sreturnType 	= Datatype(Objecttype(cname));
		sformals 		= constructor.formals;
		sbody 			= append_code_to_constructor fbody cname (Datatype(Objecttype(cname)));
		func_type		= Sast.User;
	}

let check_fbody fname fbody returnType =
	let final_stmt = List.hd (List.rev fbody) in
	match returnType, final_stmt with
		Datatype(Void_t), _ -> ()
	| 	_, SReturn(_, _) -> ()
	| 	_ -> raise(Exceptions.AllNonVoidFunctionsMustEndWithReturn(fname))

let convert_fdecl_to_sfdecl class_maps reserved class_map cname fdecl = 
	let class_formal = Ast.Formal(Datatype(Objecttype(cname)), "this") in
	let env = {
		env_class_maps 	= class_maps;
		env_name     	= cname;
		env_cmap 		= class_map;
		env_locals    	= StringMap.empty;
		env_parameters	= List.fold_left (fun m f -> match f with Formal(d, s) -> (StringMap.add s f m) | _ -> m) StringMap.empty (class_formal :: fdecl.formals);
		env_returnType	= fdecl.returnType;
		env_callStack 	= false;
		env_reserved 	= reserved;
	} in
	let fbody = fst (convert_stmt_list_to_sstmt_list env fdecl.body) in
	let fname = (get_name cname fdecl) in
	ignore(check_fbody fname fbody fdecl.returnType);
	let fbody = if fname = "main" then (append_code_to_main fbody cname (Datatype(Objecttype(cname)))) else fbody in
	(* We add the class as the first parameter to the function for codegen *)
	{
		sfname 			= Ast.FName (get_name cname fdecl);
		sreturnType 	= fdecl.returnType;
		sformals 		= class_formal :: fdecl.formals;
		sbody 			= fbody;
		func_type		= Sast.User;
	}

let convert_cdecl_to_sast (cdecl:Ast.class_decl) = 
	{
		scname = cdecl.cname;
		sfields = cdecl.cbody.fields;
	}

let convert_cdecls_to_sast class_maps reserved (cdecls:Ast.class_decl list) = 
	let handle_cdecl cdecl = 
		let class_map = StringMap.find cdecl.cname class_maps in 
		let scdecl = convert_cdecl_to_sast cdecl in
		let sconstructor_list = List.fold_left (fun l c -> (convert_constructor_to_sfdecl class_maps reserved class_map cdecl.cname c) :: l) [] cdecl.cbody.constructors in
		let func_list = List.fold_left (fun l f -> (convert_fdecl_to_sfdecl class_maps reserved class_map cdecl.cname f) :: l) [] cdecl.cbody.methods in
		(scdecl, func_list @ sconstructor_list)
	in 
		let overall_list = List.fold_left (fun t c -> let scdecl = handle_cdecl c in (fst scdecl :: fst t, snd scdecl @ snd t)) ([], []) cdecls in
		let find_main = (fun f -> match f.sfname with FName n -> n = "main" | _ -> false) in
		let mains = (List.find_all find_main (snd overall_list)) in
		let main = if List.length mains < 1 then raise Exceptions.MainNotDefined else if List.length mains > 1 then raise Exceptions.MultipleMainsDefined else List.hd mains in
		let funcs = (List.filter (fun f -> not (find_main f)) (snd overall_list)) in
		(* let funcs = (add_default_constructors cdecls class_maps) @ funcs in *)
		{
			classes 		= fst overall_list;
			functions 		= funcs;
			main 			= main;
			reserved 		= reserved;
		}

let add_reserved_functions = 
	let reserved_stub name return_type formals = 
		{
			sfname 			= FName(name);
			sreturnType 	= return_type;
			sformals 		= formals;
			sbody 			= [];
			func_type		= Sast.Reserved;
		}
	in
	let i32_t = Datatype(Int_t) in
	let void_t = Datatype(Void_t) in
	let str_t = Arraytype(Char_t, 1) in
	let mf t n = Formal(t, n) in (* Make formal *)
	let reserved = [
		reserved_stub "print" 	(void_t) 	([Many(Any)]);
		reserved_stub "malloc" 	(str_t) 	([mf i32_t "size"]);
		reserved_stub "cast" 	(Any) 		([mf Any "in"]);
		reserved_stub "sizeof" 	(i32_t) 	([mf Any "in"]);
		reserved_stub "open" 	(i32_t) 	([mf str_t "path"; mf i32_t "flags"]);
		reserved_stub "close" 	(i32_t) 	([mf i32_t "fd"]);
		reserved_stub "read" 	(i32_t) 	([mf i32_t "fd"; mf str_t "buf"; mf i32_t "nbyte"; mf i32_t "offset"]);
		reserved_stub "write" 	(i32_t) 	([mf i32_t "fd"; mf str_t "buf"; mf i32_t "nbyte"]);
		reserved_stub "lseek" 	(i32_t) 	([mf i32_t "fd"; mf i32_t "offset"; mf i32_t "whence"]);
		reserved_stub "exit" 	(void_t) 	([mf i32_t "status"]);
	] in
	reserved

(* Main method for analyzer *)
let analyze filename program = match program with
	Program(includes, classes) ->
	let cdecls = process_includes filename includes classes in
	let reserved = add_reserved_functions in
	let class_maps = build_class_maps reserved cdecls in
	let sast = convert_cdecls_to_sast class_maps reserved cdecls in
	sast
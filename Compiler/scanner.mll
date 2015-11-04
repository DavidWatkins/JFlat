{ open Parser }

let alpha = ['a'-'z' 'A'-'Z']
let ascii = ([' '-'!' '#'-'[' ']'-'~'] | '\\' ['\\' '"' 'n' 'r' 't'])
let digit = ['0'-'9']
let id = alpha (alpha | digit | '_')*
let string = '"' ( ascii* as s) '"'
let char = ''' ( ascii | digit ) '''
let float = ('-' digit+ | digit+) ['.'] digit+
let int = digit+ | '-' digit+
let whitespace = [' ' '\t' '\r' '\n']

rule token = parse
  whitespace { token lexbuf } (* Whitespace *)
| "(*"       { comment lexbuf }           (* Comments *)

| '('      { LPAREN }
| ')'      { RPAREN }
| '{'      { LBRACE }
| '}'      { RBRACE }
| ';'      { SEMI }
| ','      { COMMA }

(* Operators *)
| '+'      { PLUS }
| '-'      { MINUS }
| '*'      { TIMES }
| '/'      { DIVIDE }
| '='      { ASSIGN }
| "=="     { EQ }
| "!="     { NEQ }
| '<'      { LT }
| "<="     { LEQ }
| ">"      { GT }
| ">="     { GEQ }
| "and"    { AND }
| "or"     { OR }
| "not"    { NOT }
| '.'      { DOT }
| '['      { LBRACKET }
| ']'      { RBRACKET }
| '|'	   { BAR }

(* Branch Control *)
| "if"     { IF }
| "else"   { ELSE }
| "for"    { FOR }
| "while"  { WHILE }
| "return" { RETURN }

(* Data Types *)
| "int"    { INT }
| "float"  { FLOAT }
| "bool"   { BOOL }
| "char"   { CHAR }
| "void"   { VOID }
| "null"   { NULL }
| "true"   { TRUE }
| "false"  { FALSE }

(* Classes *)
| "class"       { CLASS }
| "constructor" { CONSTRUCTOR }
| "public"      { PUBLIC }
| "private"     { PRIVATE }
| "extends"     { EXTENDS }
| "include"     { INCLUDE }
| "this"        { THIS }
| "array"		{ ARRAY }

| int as lxm   { INT_LITERAL(int_of_string lxm) }
| float as lxm { FLOAT_LITERAL(float_of_string lxm) }
| char as lxm  { CHAR_LITERAL(String.get lxm 1) }
| string       { STRING_LITERAL(s) }
| id as lxm    { ID(lxm) }
| eof          { EOF }
| _ as char { raise (Failure("illegal character " ^ Char.escaped char)) }

and comment = parse
  "*)" { token lexbuf }
| _    { comment lexbuf }

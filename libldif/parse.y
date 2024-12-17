 /*
  * RFC 2849              LDAP Data Interchange Format             June 2000
  * Formal Syntax Definition of LDIF
  * 
  *    The following definition uses the augmented Backus-Naur Form
  *    specified in RFC 2234 [2].
  * 
  * ldif-file                = ldif-content / ldif-changes
  * ldif-content             = version-spec 1*(1*SEP ldif-attrval-record)
  * ldif-changes             = version-spec 1*(1*SEP ldif-change-record)
  * ldif-attrval-record      = dn-spec SEP 1*attrval-spec
  * ldif-change-record       = dn-spec SEP *control changerecord
  * version-spec             = "version:" FILL version-number
  */ 

%{
#include "libldif.h"

#include <assert.h>
#include <err.h>
#include <stdio.h>
#include <stdlib.h>

const char *
input_filename(void);

int yylex(void);
extern int yylineno, yyleng, yydebug;
extern char *yytext;

struct list_t {
    size_t size, capacity;
    struct attribute_t *list;
} attributes;

void
yyerror( char const *s ) {
    warnx( "%s, %s:%d at '%.*s'",
           s, input_filename(), yylineno, yyleng, yytext);
}

ldif_dn_t ldif_dn;
ldif_attr_t ldif_attr;

static bool
call_dn_cb(  
	    const char dn[],
	    size_t nattr,
	    struct attribute_t attrs[] )
{
    return ldif_dn ? ldif_dn(dn, nattr, attrs) : true;
}

static bool
call_attr_cb( struct attribute_t *attr) {
    return ldif_attr? ldif_attr(attr) : true;
}

static struct attribute_t *
add_attr( const char name[], const char value[] ) {
    if( attributes.size == attributes.capacity ) {
	struct list_t attrs = attributes;
	attrs.capacity = attrs.capacity == 0? 32 : 2 * attrs.capacity;
	attrs.list = realloc(attributes.list,
			      sizeof(attrs.list[0]) * attrs.capacity);
	if( attrs.list == NULL ) {
	    err( EXIT_FAILURE, "could not allocate attribute list" );
	}
        attributes = attrs;
    }

    struct attribute_t attr = { .value = (char*)value };
    size_t len = snprintf( attr.name, sizeof(attr.name), "%s", name );
    if( sizeof(attr.name) <= len ) {
	warnx( "trunctated %s as '%.*s'", name, (int)sizeof(attr.name), name );
    }
    struct attribute_t *p = attributes.list + attributes.size++;
    *p = attr;

    return p;
}

%}

%token BASE64_STRING
%token FILL
%token SAFE_STRING SEP

%token ATTR_TYPE ATTR_TYPE_CHARS
%token CHANGETYPE CONTROL DN NUMBER
%token TRUE_kw FALSE_kw
			
%token ADD DELETE MODIFY REPLACE
%token MODDN MODRDN NEWRDN DELETEOLDRDN NEWSUPERIOR
%token VERSION

%define api.value.type {char *}

%%

ldif_file:	ldif_content
	| 	ldif_changes
		;

ldif_content:	version_spec ldif_attrval_records
		;

ldif_attrval_records:
		ldif_attrval_record
	|	ldif_attrval_records seps ldif_attrval_record
		{ /* An ldif_attrval_record is a DN + 1 or more
		     attrval_specs, each one ending with SEP
		     (newline). Records themselves are separated by
		     one or more blank lines, indicated by seps,
		     above. */
		}
		;
ldif_attrval_record:
		dn_spec SEP attrval_specs
		{
		    if( ! call_dn_cb($1, attributes.size, attributes.list) ) {
			YYABORT;
		    }
		    attributes.size = 0;
		}
		;
attrval_specs:	attrval_spec
	|	attrval_specs attrval_spec
		;
attrval_spec:	AttributeDescription value_spec SEP
		{
		    struct attribute_t *p = add_attr($1, $2);
		    call_attr_cb(p);
		}
		;

ldif_changes:	version_spec ldif_change_records
	|	version_spec ldif_change_records seps
		;
ldif_change_records:
		ldif_change_record
	|	ldif_change_records seps ldif_change_record
		;
ldif_change_record:
		dn_spec SEP control SEP changerecord
	|	dn_spec SEP             changerecord
		;

version_spec:	%empty
	|	seps
	|	VERSION fill NUMBER seps
		;

dn_spec: 	DN     fill distinguishedName
		{ $$ = $3; }
	| 	DN ':' fill base64_distinguishedName
		{ $$ = $4; }
		;

distinguishedName:
		SAFE_STRING
		;
		
base64_distinguishedName:
		BASE64_STRING
		;

rdn:		SAFE_STRING
		;

base64_rdn:	base64_utf8_string
		;

base64_utf8_string:  BASE64_STRING
		;

control:	CONTROL fill ldap_oid fill true_false value_spec
	|	CONTROL fill ldap_oid fill true_false
		;
true_false:	%empty
	|	TRUE_kw
	|	FALSE_kw
		;

value_spec:	':'     fill                 { $$ = "no value"; }
	|	':'     fill SAFE_STRING     { $$ = $3; }
	|	':' ':' fill BASE64_STRING   { $$ = $4; }
	|	'<'     fill url             { $$ = $3; }
		;
url:		SAFE_STRING
		{ /* Todo: see RFC 2849, Note #6 */
		    $$ = $1;
		}
		;

ldap_oid:  	NUMBER
	|	NUMBER '.' NUMBER
		;

AttributeDescription:
		AttributeType
	|	AttributeType ';' options
		;

AttributeType:	ldap_oid
	| 	ATTR_TYPE
		;

options:	option
	| 	options ';' option
		;

option:         ATTR_TYPE_CHARS
	|	ATTR_TYPE
		;

changerecord:	CHANGETYPE fill change_add
	| 	CHANGETYPE fill change_delete 
	| 	CHANGETYPE fill change_moddn
	|	CHANGETYPE fill change_modify
		;

change_add:	ADD SEP attrval_specs
		;

change_delete:	DELETE SEP
		;

change_moddn:	mod_rdn SEP NEWRDN fill tgt_rdn SEP
		DELETEOLDRDN fill zero_one SEP new_superior
		;
mod_rdn:	MODRDN
	|	MODDN
		;
tgt_rdn:	rdn 
	| 	':' fill base64_rdn
		;
zero_one:	'0'
	|	'1'
		;
new_superior: 	%empty
	|	NEWSUPERIOR distinguished_name SEP
		;

distinguished_name:
		fill distinguishedName
	| 	':' fill base64_distinguishedName
		;

change_modify: 	MODIFY SEP mod_specs
	|	MODIFY SEP 
		;

mod_specs:	mod_spec
	|	mod_specs mod_spec
	;

mod_spec:       verb fill AttributeDescription SEP attrval_specs
		{
		    if( yychar == YYEOF ) {
			YYACCEPT;
		    }
		}
		'-' SEP
	|	verb fill AttributeDescription SEP
		{
		    if( yychar == YYEOF ) {
			YYACCEPT;
		    }
		}
		'-' SEP
	|	verb fill AttributeDescription SEP attrval_spec
		;

verb:		ADD
	| 	DELETE
	| 	REPLACE
		;

seps:		SEP
		{
		    if( yychar == YYEOF ) {
			YYACCEPT;
		    }
		}
	|	seps
		{
		    if( yychar == YYEOF ) {
			YYACCEPT;
		    }
		}
		SEP
	;

fill:		%empty
	|	FILL
	;

%%

static bool
ldif_input_print(  ) {
    printf( "end input\n" );
    return true;
}

static bool
ldif_dn_print( const char dn[],
	       size_t nattr,
	       struct attribute_t attrs[] ) {
    assert(dn);
    assert(attrs);

    printf( "\t%s\n", dn );
    for( const struct attribute_t  *attr = attrs;
	 attr < attrs + nattr; attr++ ) {
	printf( "\t%8zu %s = %s\n",
		1 + (attr - attrs), 
		attr->name,
		attr->value? attr->value : "(none)" );
    }
    printf( "\n" );
    return true;
}    

static bool
ldif_attr_print( struct attribute_t *attr ) {
    assert(attr);

    printf( "\t\t{%s = %s}\n", attr->name, attr->value );

    return true;
}

void 
set_print_callbacks(void) {
    ldif_dn = ldif_dn_print;
}

%{
#include "parse.h"

#include <assert.h>
#include <ctype.h>
#include <err.h>
#include <stdbool.h>

static bool is_base64 = false;
static bool at_eof = false;

static int read_block( char block[], int nbyte );
#define YY_INPUT(buf, result, max_size) 	\
	int c = read_block( buf, max_size);	\
	result = (c == EOF) ? YY_NULL : c;	

#define YY_USER_ACTION                                                  \
	if( yy_flex_debug )                                             \
		warnx("lineno: %d, rule #%d", yylineno, yy_act);

%}

SPACE                      [[:blank:]]
FILL                       {SPACE}+

SEP                        \r?\n

ALPHA                      [[:alpha:]]
DIGIT                      [[:digit:]]

ATTR_TYPE_CHARS		   [[:alnum:]-]

UTF8_1                     [\x80-\xBF]
UTF8_2                     [\xC0-\xDF]{UTF8_1}
UTF8_3                     [\xE0-\xEF]{2}{UTF8_1}
UTF8_4                     [\xF0-\xF7]{3}{UTF8_1}
UTF8_5                     [\xF8-\xFB]{4}{UTF8_1}
UTF8_6                     [\xFC-\xFD]{5}{UTF8_1}

			   /* any value <= 127 decimal except NUL, LF, and CR*/
SAFE_CHAR                  [\x01-\x7F]{-}[\r\n]
			   /* also exclude SPACE, colon, and less-than */
SAFE_INIT_CHAR             [\x01-\x7F]{-}[\r\n :<]

SAFE_STRING                {SAFE_INIT_CHAR}{SAFE_CHAR}*

UTF8_CHAR                  {SAFE_CHAR}|{UTF8_2}|{UTF8_3}|{UTF8_4}|{UTF8_5}|{UTF8_6}

UTF8_STRING                {UTF8_CHAR}+

				      /*  +, /, 0-9, =, A-Z, and a-z */
BASE64_CHAR                [[:alnum:]+/=]
BASE64_STRING              {BASE64_CHAR}+

%option debug noyywrap stack yylineno nodefault
%x value changeverb

%%

{SEP}{FILL}		{ return FILL; }

{FILL}			{ yylval = strdup(yytext); return FILL; }
{SEP}			{ yylval = strdup(yytext); return SEP; }

{DIGIT}+		{ yylval = strdup(yytext); return NUMBER; }

true			{ yylval = strdup(yytext); return TRUE_kw; }
false			{ yylval = strdup(yytext); return FALSE_kw; }

dn:/{SPACE}*{SAFE_STRING} { yylval = strdup(yytext);
       			  yy_push_state(value);
			  return DN; }
version[:]		{ yylval = strdup(yytext); 
       			  yy_push_state(value);
			  return VERSION; }
control[:]		{ yylval = strdup(yytext); 
       			  yy_push_state(value);
			  return CONTROL; }
changetype[:]		{ yylval = strdup(yytext); 
       			  yy_push_state(changeverb);
			  return CHANGETYPE; }
<changeverb>{
{FILL}
add			{ yy_pop_state(); return ADD; }
delete			{ yy_pop_state(); return DELETE; }
modify			{ yy_pop_state(); return MODIFY; }
replace			{ yy_pop_state(); return REPLACE; }
moddn			{ yy_pop_state(); return MODDN; }
modrdn			{ yy_pop_state(); return MODRDN; }
newrdn			{ yy_pop_state(); return NEWRDN; }
deleteoldrdn		{ yy_pop_state(); return DELETEOLDRDN; }
newsuperior		{ yy_pop_state(); return NEWSUPERIOR; }
.|\n    		{ warnx( "invalid default rule in <changeverb>" );
    			  return *yytext; }
}

add[:]			{ return ADD; }
delete[:]		{ return DELETE; }
replace[:]		{ return REPLACE; }

[:]/{SPACE}*\n		{ return *yytext; }
		
[:]			{ yy_push_state(value);      return *yytext; }

<<EOF>>                 { if( !at_eof ) {
	                  /* possibly missing NL on last line */
	                    at_eof = true;
			    return SEP;
                          }
		          return YY_NULL;
		        }

{ALPHA}{ATTR_TYPE_CHARS}* { yylval = strdup(yytext); return ATTR_TYPE; }

{ATTR_TYPE_CHARS}	{ if( yyleng == 1 && *yytext == '-' ) {
			      return *yytext;
			  }
			  yylval = strdup(yytext);
			  return ATTR_TYPE_CHARS; }

<value>{
    {SPACE}		{}
    [:]{SPACE}*		{ is_base64 = true; return *yytext; }
		
    {BASE64_STRING} 	{ yylval = strdup(yytext);
			  int type = is_base64? BASE64_STRING : SAFE_STRING;
			  is_base64 = false;
			  yy_pop_state(); 
			  return type; }
		
    {SAFE_STRING}	{ yylval = strdup(yytext); 
			  is_base64 = false;
			  yy_pop_state(); 
			  return SAFE_STRING; }
		
    .|\n		{ warnx("default rule in <value>"); return *yytext; }
}
		
^#.*\r?\n		{ if( yy_flex_debug && !YY_AT_BOL() ) {
        		    warnx("not at BOL"); }}

.		        { warnx("accepted unknown character 0x%02x",
                                *yytext);
                          return *yytext; }

%%

/*
 * Overwrite line-continuation characters. (Unfold folded lines.)
 */
static int
read_block( char block[], int nbyte ) {
    size_t len = fread(block, 1, nbyte-1, yyin);
    for( char *p=block; p < block + len; p++ ) {
	if( *p != '\n' ) {
	    continue;
	}
	if( p + 1 == block + len ) { // last character
            int ch;
	    if( (ch = fgetc(yyin)) == EOF ) {
		return len;
	    }
            assert(0 < ch && ch < 256);
            p[1] = ch;
	    len++;
	}
	
	if( p[1] != 0x20 ) {
	    continue;
	}
	/*
	 * "When joining folded lines, exactly one space character at
	 *  the beginning of each continued line must be discarded."
	 *
	 * Remove the newline and leading blank by shifting any
	 * remaining data 2 bytes "to the left".
	 *
	 * Because line unfolding is done here, by adjusting the
	 * input, flex never sees them, and yylineno reports the
	 * logical line count, not the physical line number.
	 */
	assert(p + 2 <= block + len);
	assert(2 <= len);

	if( p + 2 < block + len ) {  // if something's there
	    memmove(p, p + 2, (block + len) - (p + 2)); 
	}
	len -= 2;
    }
    return len;
}


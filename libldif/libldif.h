#ifndef _LIBLDIF_H_
#define _LIBLDIF_H_

#include <stdbool.h>
#include <stdlib.h>

struct attribute_t {
  char name[30], *value;
};

/*
 * Callback types
 */
typedef bool (*ldif_dn_t)( const char dn[],
			   size_t nattr,
			   struct attribute_t attrs[] );

typedef bool (*ldif_attr_t)( struct attribute_t *attr );

/*
 * Callbacks
 */
extern ldif_dn_t ldif_dn;
extern ldif_attr_t ldif_attr;

/*
 * Public functions
 */
void 
set_print_callbacks(void);

int yyparse (void);

#endif

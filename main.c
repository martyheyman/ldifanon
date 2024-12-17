#include "libldif.h"

#include <assert.h>
#include <err.h>
#include <errno.h>
#include <fcntl.h>
#include <libgen.h>
#include <search.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <syslog.h>
#include <time.h>
#include <unistd.h>

#include <sys/stat.h>
#include <sys/types.h>

#include <sqlite3.h>

#define COUNT_OF(x) (sizeof(x)/sizeof(x[0]))

static size_t nDN = 0;

extern FILE* yyin;

const char *filename = "stdin";

extern int yydebug, yy_flex_debug;
  
const char *
input_filename(void) { return filename; }

static const char options[] = "b:d:lno:pvw:y";

static void
usage( const char name[] ) {
  fprintf( stderr, "%s [-%s] filename [filename ...]\n", name, options );
  exit( EXIT_FAILURE );
}

static void
errorLogCallback(void *pArg, int iErrCode, const char *zMsg) {
  switch(iErrCode) {
  case SQLITE_WARNING_AUTOINDEX:
    return;
  }
  warnx("error: %s: %s", sqlite3_errstr(iErrCode), zMsg);
}


typedef char attrname_t[30];

struct wblist_t {
  size_t size, capacity;
  attrname_t *list;
} wblist;

static int attrcmp( const void *K, const void *E ) { return strcmp(K, E); }

void
attributes_init( const char filename[], FILE * input ) {
  char *name;
  int n;

  while( (n = fscanf(input, "%ms", &name)) == 1 ) {
    if( wblist.size == wblist.capacity ) { 
	struct wblist_t attrs = wblist;
	attrs.capacity = attrs.capacity == 0? 32 : 2 * attrs.capacity;
	attrs.list = realloc(wblist.list,
			      sizeof(attrs.list[0]) * attrs.capacity);
	if( attrs.list == NULL ) {
	    err( EXIT_FAILURE, "could not allocate white/black list" );
	}
        wblist = attrs;
    }

    attrname_t attrname;

    if( strlen(name) != snprintf(attrname, sizeof(attrname), "%s", name) ) {
      errx( EXIT_FAILURE, "fatal: %s:%d: name '%s' in %s is too long",
	    __func__, __LINE__, name, filename );
    }

    lsearch(attrname, wblist.list,
		&wblist.size, sizeof(wblist.list[0]), attrcmp);
  }
  warnx("%zu attribute names found in %s", wblist.size, filename);
}
    
// I/O options
struct arg_t {
  char *name;
  FILE *file;
};
struct args_t {
  struct arg_t output, database, whitelist, blacklist;
  char **list;
  sqlite3 *db;
} files;

static void
transact( const char sql[] ) {
  char *msg;
  int erc = sqlite3_exec(files.db, sql, NULL, NULL, &msg);
  if( erc != SQLITE_OK ) {
    errx( EXIT_FAILURE, "fatal: %s: sqlite3_exec: %s (%s)",
	  sql, msg, sqlite3_errstr(erc) );
  }
}

static size_t
max_dn_ordinal() {
  static const char sql[] =
    "SELECT MAX(ordinal) as ordinal from DNs";
  sqlite3_stmt *stmt;
  sqlite3_int64 ordinal = 0;
 
  const char *tail;
  int erc;

  if( (erc = sqlite3_prepare(files.db, sql, -1, &stmt, &tail)) != SQLITE_OK ) {
    errx(EXIT_FAILURE, "fatal: %s: sqlite3_prepare", __func__ );
  }

  erc = sqlite3_step(stmt);

  switch( erc ) {
  case SQLITE_ROW:
    ordinal = sqlite3_column_int64(stmt, 0);
    if( 0 < ordinal ) {
      warnx("%s: max ordinal is %lld", __func__, ordinal);
    }
    break;
  case SQLITE_DONE:  // no rows
    break;
  default:
    errx(EXIT_FAILURE, "fatal: %s: sqlite3_step", __func__ );
    break;
  }
  
  if( (erc = sqlite3_finalize(stmt)) != SQLITE_OK ) {
    errx(EXIT_FAILURE, "fatal: %s: sqlite3_finalize", __func__ );
  }    

  return ordinal;
}

void
initialize( bool fnew, const char input_filename[] ) {
  struct arg_t *list = NULL;
  
  files.output.file = stdout;

  // Open white/black list
  if( files.blacklist.name ) {
    if( files.whitelist.name ) {
      errx(EXIT_FAILURE, "both black- and white-list provided");
    }
    list = &files.blacklist;
  } else {
    if( files.whitelist.name ) {
      list = &files.whitelist;
    } else {
      warnx("neither black- nor white-list provided: anonymizing all strings");
    }
  }
  if( list ) {
    if( (list->file = fopen(list->name, "r")) == NULL ) {
      err( EXIT_FAILURE, "could not open list '%s'", list->name );
    }

    attributes_init( list->name, list->file );
  }
  
  // Open output
  if( files.output.name ) {
    struct arg_t *p = &files.output;
    if( (p->file = fopen(p->name, "w+")) == NULL ) {
      err( EXIT_FAILURE, "could not open '%s' for output", p->name );
    }
  }

  assert(input_filename);
  const char *input = input_filename[0] == '-'? "stdin" : input_filename;

  // Open database
  if( !files.database.name ) {
    const char *stem = files.output.name ? files.output.name : input;
    int n = asprintf( &files.database.name, "%s.db", stem );
    if( n < 0 ) {
      err( EXIT_FAILURE, "could not allocate database name" );
    }
  }
  
  if( fnew ) {
    if( -1 == unlink(files.database.name) ) {
      if( errno != ENOENT ) {
	err(EXIT_FAILURE, "could not remove %s", files.database.name);
      }
    }
  }

  // If status(2) returns an error, assume the database doesn't exist. 
  struct stat sb;
  fnew = -1 == stat(files.database.name, &sb);
  
  static void * pData = NULL;
  sqlite3_config(SQLITE_CONFIG_LOG, errorLogCallback, pData);

  if( sqlite3_open(files.database.name, &files.db) != SQLITE_OK ) {
    errx( EXIT_FAILURE, "could not open database %s", files.database.name );
  }

  if( fnew ) {
    static const char 
      dns[] = 
      "create table DNs ("
      "\n" "  dn text not NULL, "
      "\n" "  ordinal integer not NULL check (typeof(ordinal) = 'integer'), "
      "\n" "primary key (dn), "
      "\n" "unique (ordinal) "
      ")" 
      ,
      attrs[] = 
      "create table attrs ("
      "\n" "  dn text not NULL, "
      "\n" "  attribute text not NULL, "
      "\n" "  value text not NULL, "
      "\n" "  ordinal integer not NULL check (typeof(ordinal) = 'integer'), "
      "\n" "primary key (dn, attribute, value), "
      "\n" "unique (dn, ordinal) "
      "\n" "foreign key (dn) references DNs (dn)"
      ")" 
      ,
      ldif[] = 
      "create view ldif "
      "\n" "as "
      "\n" "select D.ordinal as did, 0 as aid, 'dn: ' || D.dn as 'orig' "
      "\n" "from DNs as D "
      "\n" "UNION "
      "\n" "select D.ordinal, A.ordinal,  "
      "\n" "       A.attribute || ': ' || A.value as 'attribute' "
      "\n" "from DNs as D join attrs as A "
      "\n" "on D.dn = A.dn "
      ;

    transact(dns);
    transact(attrs);
    transact(ldif);
  }
  nDN = max_dn_ordinal();
}

static void
print_ldif( const char dn[], size_t ordinal, size_t 
	    nattr, struct attribute_t attrs[] ) {
  FILE *out = files.output.file;
  assert(out);
  
  ////fprintf(out, "# DN %zu is '%s'\n", ordinal, dn);
  fprintf(out, "dn: %zu\n", ordinal);

  for( struct attribute_t *attr = attrs; attr < attrs + nattr; attr++ ) {
    fprintf(out, "%s: %s\n", attr->name, attr->value);
  }

  fprintf(out, "\n"); // blank line between records
}

static bool
is_candidate( const char name[], const char value[] ) {
  // if whitelist and not found, a candidate
  // if blacklist and     found, a candidate
  // if no list defined, any string value is a candidate

  assert(name);
  
  if( files.whitelist.name || files.blacklist.name ) {
    size_t n = wblist.size;
    const char *p = lfind(name, wblist.list,
			  &n, sizeof(wblist.list[0]), attrcmp);

    return files.whitelist.name && !p
      ||   files.blacklist.name &&  p; 
  }

  double d;
  long i;
  char c;

  // numbers are not candidates
  if( 1 == sscanf(value, "%lf%c", &d, &c) ) return false;
  if( 1 == sscanf(value, "%ld%c", &i, &c) ) return false;
  
  return true;
}


static void
insert_dn( const char dn[], size_t ordinal ) {
  static const char sql[] =
    "INSERT INTO DNs (dn, ordinal) "
    "VALUES ( ?, ? );";
  sqlite3_stmt *stmt;
 
  const char *tail;
  int erc;

  if( (erc = sqlite3_prepare(files.db, sql, -1, &stmt, &tail)) != SQLITE_OK ) {
    errx(EXIT_FAILURE, "fatal: %s: sqlite3_prepare", __func__ );
  }

  erc = sqlite3_bind_text(stmt, 1, dn, -1, SQLITE_STATIC);
  if( erc != SQLITE_OK ) {
    errx(EXIT_FAILURE, "fatal: %s: sqlite3_bind[1]: %s",
	 __func__, sqlite3_errstr(erc) );
  }

  // Must use integer bind, else constraint fails.
  if( (erc = sqlite3_bind_int64(stmt, 2, ordinal)) != SQLITE_OK ) {
    errx(EXIT_FAILURE, "fatal: %s: sqlite3_bind[2]: %s",
	 __func__, sqlite3_errstr(erc) );
  }

  if( (erc = sqlite3_step(stmt)) != SQLITE_DONE ) {
    errx(EXIT_FAILURE, "fatal: %s: sqlite3_step: ordinal #%zu: %s", __func__, ordinal, dn );
  }    

  if( (erc = sqlite3_finalize(stmt)) != SQLITE_OK ) {
    errx(EXIT_FAILURE, "fatal: %s: sqlite3_finalize", __func__ );
  }    
}

char *
insert_value( const char dn[], size_t ordinal, const struct attribute_t attr ) {
  static const char sql[] =
    "INSERT INTO attrs (dn, attribute, value, ordinal) "
    "VALUES ( ?, ?, ?, ? );";
  sqlite3_stmt *stmt;
 
  const char *tail;
  int erc;

  if( (erc = sqlite3_prepare(files.db, sql, -1, &stmt, &tail)) != SQLITE_OK ) {
    errx(EXIT_FAILURE, "fatal: %s: sqlite3_prepare", __func__ );
  }

  const char *args[] = { dn, attr.name, attr.value };

  for( int i=0; i < COUNT_OF(args); i++ ) {
    erc = sqlite3_bind_text(stmt, i+1, args[i], -1, SQLITE_STATIC);
    if( erc != SQLITE_OK ) {
      errx(EXIT_FAILURE, "fatal: %s: sqlite3_bind[%d]: %s",
	   __func__, i+1, sqlite3_errstr(erc) );
    }
  }

  // Must use integer bind, else constraint fails.
  erc = sqlite3_bind_int64(stmt, 1 + COUNT_OF(args), ordinal);
  if( erc != SQLITE_OK ) {
    errx(EXIT_FAILURE, "fatal: %s: sqlite3_bind[%zu]: %s",
	 __func__, 1 + COUNT_OF(args), sqlite3_errstr(erc) );
  }

  if( (erc = sqlite3_step(stmt)) != SQLITE_DONE ) {
    for( int i=0; i < COUNT_OF(args); i++ ) {
      warnx( "%4d: %s", i+1, args[i]);
    }
    errx(EXIT_FAILURE, "fatal: %s: sqlite3_step", __func__ );
  }    

  if( (erc = sqlite3_finalize(stmt)) != SQLITE_OK ) {
    errx(EXIT_FAILURE, "fatal: %s: sqlite3_finalize", __func__ );
  }    

  char *anon;
  (void)! asprintf(&anon, "%zu", ordinal);

  return anon;
}

static void
free_dn( size_t nattr, struct attribute_t attrs[], struct attribute_t anon[] ) {
  for( size_t i=0; i < nattr; i++ ) {
    if( anon[i].value != attrs[i].value ) {
      free(anon[i].value);
    }
    free(attrs[i].value);
  }
}

/*
 * For each DN: 
 * 1) build anonymization pairs for eligible attributes (maybe DN too)
 * 2) generate SQL and execute for replacements 
 * 3) print new LDIF on output
 */
static bool
anonymize( const char dn[], size_t nattr, struct attribute_t attrs[] ) {
  assert(dn);
  assert(attrs);
  assert(files.db);

  struct attribute_t anon_attrs[nattr];

  insert_dn(dn, ++nDN);

  // store and produce anonymous values
  for( struct attribute_t *a = attrs; a < attrs + nattr; a++ ) {
    anon_attrs[a - attrs] = *a;
    if( !is_candidate(a->name, a->value) ) {
      continue;
    }
    // anonymous value is simply the nth candidate for this DN
    anon_attrs[a - attrs].value = insert_value(dn, 1 + (a - attrs), *a);
  }
    
  print_ldif( dn, nDN, nattr, anon_attrs );

  free_dn(nattr, attrs, anon_attrs);

  return true;
}

static int
process( FILE* input ) {
  extern int yylineno;
  assert(input);

  if( input != stdin ) {
    yyin = input;
  }

  yylineno = 1;
  ldif_dn = anonymize;
  
  return yyparse();
}

int
main(int argc, char *argv[])
{
  FILE *input;
  int opt, status;
  bool fverbose = false;
  
  bool fnew = false;
  yy_flex_debug = 0;
  yydebug = 0;

  //// ldifanon [-n] [-o output] [-d database] [-w whitelist | -b blacklist]
  
  while ((opt = getopt(argc, argv, options)) != -1) {
    switch (opt) {
    case 'n':
      fnew = true;
      break;
    case 'o':
      files.output.name = optarg;
      break;
    case 'd':
      files.database.name = optarg;
      break;
    case 'w':
      files.whitelist.name = optarg;
      break;
    case 'b':
      files.blacklist.name = optarg;
      break;

    case 'l': // flex debugging
      yy_flex_debug = 1;
      break;
    case 'p':
      set_print_callbacks();      
      break;
    case 'v': // verbose
      fverbose = true;
      break;
    case 'y': // yacc debugging
      yydebug = 1;
      break;
    default: 
      usage(basename(argv[0]));
      abort(); // not reached
    }
  }

  if( optind == argc ) {
    errx( EXIT_FAILURE, "error: no input filename");
  }
  
  for( int i = optind; i < argc; i++ ) {
    filename = argv[i];
    if( i == optind ) {
      initialize( fnew, filename );
    }
    if( 0 == strcmp(filename, "-") ) {
      input = stdin;
    } else {
      if( (input = fopen(filename, "r")) == NULL ) {
	err(EXIT_FAILURE, "cannot open '%s'", filename);
      }
      if( fverbose ) {
	warnx("reading %s", filename);
      }
    }

    static const char begin_txn[] = "BEGIN TRANSACTION;";
    static const char commit_txn[] = "COMMIT TRANSACTION;";

    transact(begin_txn);
      
    if( (status = process(input)) != 0 ) {
      return status;
    }

    transact(commit_txn);

    (void)fclose(input);
  }

  return EXIT_SUCCESS;
}

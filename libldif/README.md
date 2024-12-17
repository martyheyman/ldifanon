# A sketch of the idea

**libldif.so** will parse an input LDIF file.  The user (of the
library) provides callback functions to do "something" when the parser
encounters "interesting" bits of the file. If no callback is provided
a given "interesting" bit, the default behavior is invoked. That
default may be to print the interesting bit, or not. 

LDIF records may be of two types: 

  * Attribute values for a DN
  * Attribute changes for a DN
  
A DN is defined by a set of name-value pairs. A callback can be provided for:

  * for each DN, with an array of name-value pairs
  * for each  of attribute, with name and value



This library is derived from my earlier noodle, ldap-clap, which
didn't do much.


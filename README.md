# ldifanon

An anonymizer for LDAP Interchange Format (LDIF) data. 

This program reads an LDIF file, and modifies attribute values specified in the configuration settings to hash-values. This is a one-way hash and can not be reversed. It generates repeatable hashes so that multiple LDIF files, run through the program, will have the same hashes for the same attribute values.

For an example of usage, see: https://kb.symas.com/ldifanon-example-input-and-anonymized-output?from_search=169323140

A man-page is included in the package.

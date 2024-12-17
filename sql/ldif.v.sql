-- These views are not applied to the database when it's created.
--
-- All necessary DDL (including the ldif view) is applied when the
-- database is created, by the initialize() function in main.c.

drop view if exists attr
;

create view attr
as
select D.dn, A.attribute || ': ' || A.value as 'attribute' 
from DNs as D join attrs as A
on D.ordinal = A.ordinal
;


drop view if exists ldif
;

create view ldif
as
select D.ordinal as did, 0 as aid, 'dn: ' || D.dn as 'orig'
from DNs as D
UNION
select D.ordinal, A.ordinal, A.attribute || ': ' || A.value as 'attribute' 
from DNs as D join attrs as A
on D.ordinal = A.ordinal
;

select orig from ldif
where did < 4
order by did, aid
;

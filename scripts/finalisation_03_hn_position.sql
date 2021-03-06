--------------------------------------------------------------------------
--  Appariement/Regroupement des hns des différentes sources dans 
--   la table housenumber
--  Appariement/Regroupement des positions des différentes sources dans
--   la table position
--------------------------------------------------------------------------

\set ON_ERROR_STOP 1
\timing

DROP TABLE IF EXISTS housenumber;

-- dgfip 
CREATE TABLE housenumber AS SELECT g.id_fantoir as group_fantoir, g.id_pseudo_fpb as group_ign, g.co_voie as group_laposte, h.number, h.ordinal, g.code_insee, true::bool as source_dgfip, max(destination) as destination, h.code_postal as code_post_dgfip
FROM dgfip_housenumbers h, group_fnal g 
WHERE fantoir=g.id_fantoir
--and h.insee_com like '94%' 
GROUP BY g.id_fantoir, g.id_pseudo_fpb, g.co_voie, h.number, h.ordinal, g.code_insee, h.code_postal;

-- mise à jour de l'id ign sur housenumber pour les hn dont le group ign, le numero et l'ordinal sont deja présents
-- on récupère aussi le code postal sur la table ign
DROP TABLE IF EXISTS housenumber_temp;
CREATE TABLE housenumber_temp AS SELECT h.*, i.id as ign, i.code_post as code_post_ign FROM housenumber h
LEFT JOIN ign_housenumber_unique i ON (h.group_ign = i.id_pseudo_fpb and h.number=i.numero and h.ordinal=i.rep);
DROP TABLE housenumber;
ALTER TABLE housenumber_temp RENAME TO housenumber;
CREATE INDEX idx_housenumber_ign ON housenumber(ign);

-- ajout des hn ign pas encore ajoutés 
INSERT INTO housenumber(ign,group_fantoir,group_ign,group_laposte,number,ordinal,code_insee,code_post_ign) 
SELECT i.id, g.id_fantoir,i.id_pseudo_fpb, g.co_voie, i.numero, i.rep, g.code_insee, i.code_post from ign_housenumber_unique i
left join housenumber h on (h.ign = i.id)
LEFT JOIN group_fnal g ON (g.id_pseudo_fpb = i.id_pseudo_fpb)
WHERE h.ign is null and g.id_pseudo_fpb is not null;

-- mise à jour de l'id poste sur housenumber pour les hn dont le group poste, le numero et l'ordinal sont deja présents
-- on met aussi à jour le code postal et la ligne 5
DROP TABLE IF EXISTS housenumber_temp;
CREATE TABLE housenumber_temp AS SELECT h.*, p.co_cea as laposte, p.co_postal, p.lb_l5 FROM housenumber h
LEFT JOIN ran_housenumber as p ON (h.group_laposte = p.co_voie and h.number=p.no_voie and h.ordinal=p.lb_ext);
DROP TABLE housenumber;
ALTER TABLE housenumber_temp RENAME TO housenumber;
CREATE INDEX idx_housenumber_laposte ON housenumber(laposte);

-- ajout des hn laposte pas encore ajoutés
INSERT INTO housenumber(laposte,group_fantoir,group_ign,group_laposte,number,ordinal,code_insee,co_postal,lb_l5)
SELECT p.co_cea, g.id_fantoir, g.id_pseudo_fpb,p.co_voie, p.no_voie, p.lb_ext, g.code_insee, p.co_postal, p.lb_l5 from ran_housenumber p
left join housenumber h on (h.laposte = p.co_cea)
LEFT JOIN group_fnal g ON (g.co_voie = p.co_voie)
WHERE h.laposte is null and g.co_voie is not null
;
--AND co_insee like '94%';

-- si le co_postal est vide, on le remplit avec le code postal ign
UPDATE housenumber SET co_postal = code_post_ign WHERE (co_postal is null or co_postal = '') and (code_post_ign is not null and code_post_ign <> '');

-- si le co_postal est vide, on le remplit avec le code postal dgfip
UPDATE housenumber SET co_postal = code_post_dgfip WHERE (co_postal is null or co_postal = '') and (code_post_dgfip is not null and code_post_dgfip <> '');

-- ajout CIA, source_init
DROP TABLE IF EXISTS housenumber_temp;
CREATE TABLE housenumber_temp AS SELECT *, CASE WHEN group_fantoir is not null THEN upper(format('%s_%s_%s_%s',left(group_fantoir,5),right(group_fantoir,4),number, coalesce(ordinal,''))) ELSE null END as cia, array_to_string(array[CASE WHEN source_dgfip is true THEN 'DGFIP' ELSE null END,CASE WHEN ign is null THEN null ELSE 'IGN' END,CASE WHEN laposte is null THEN null ELSE 'LAPOSTE' END],'|') as source_init FROM housenumber;
DROP TABLE housenumber;
ALTER TABLE housenumber_temp RENAME TO housenumber;



-- marquage/suppression des hn IGN pointant vers des groupes ign sans nom
drop table if exists ign_housenumber_sans_nom;
create table ign_housenumber_sans_nom as select h.* from housenumber h left join ign_group_sans_nom g on (h.group_ign = g.id_pseudo_fpb) where h.group_ign is not null and h.group_ign <> '' and g.id_pseudo_fpb is not null;
delete from housenumber h using ign_group_sans_nom g where (h.group_ign = g.id_pseudo_fpb) and h.group_ign is not null and h.group_ign <> '' and g.id_pseudo_fpb is not null;
create index idx_ign_housenumber_sans_nom_ign on ign_housenumber_sans_nom(ign);

-- quelques indexes
CREATE INDEX idx_housenumber_cia ON housenumber(cia);
CREATE INDEX idx_housenumber_ign ON housenumber(ign);
CREATE INDEX idx_housenumber_laposte ON housenumber(laposte);

-- on vide les liens codes postaux -> hn non cohérents, cad qui ne pointent pas vers un cp existants ou unique au sens (code insee, code postal, ligne 5)
-- 2 cas observés :
-- hn ign avec cp, mais la poste pour ce cp a plusieurs lignes 5 et aucune vide. On ne sait pas vers quel cp faire pointer
-- hn avec incohérence entre l'insee poste et l'insee ign
create index idx_poste_cp_co_insee on poste_cp(co_insee);
create index idx_poste_cp_co_postal on poste_cp(co_postal);
DROP TABLE IF EXISTS housenumber_cp_error;
create table housenumber_cp_error as select h.*,lb_l5_nn from housenumber h left join (select * from poste_cp where lb_l5_nn is null) p on (h.code_insee = p.co_insee and h.co_postal = p.co_postal ) where h.co_postal is not null and p.co_insee is null and lb_l5 is null;
create index idx_housenumber_cp_error_ign on housenumber_cp_error(ign);
create index idx_housenumber_cp_error_laposte on housenumber_cp_error(laposte);

drop table if exists anomalies_cp_insee;
create table anomalies_cp_insee as select a.*, co_insee as co_insee_lp 
   from (select h.ign,h.laposte,h.code_insee,h.co_postal, h.lb_l5, 'insee, code postal, l5 pas trouve dans post code'::varchar as libelle, ''::varchar as libelle2 from housenumber h
   	left join  housenumber_cp_error h2 on (h.ign = h2.ign)
   	where h.ign is not null and h.ign <> '' and h2.ign is not null) as a
   left join ran_housenumber p on (a.laposte = p.co_cea) ;
update anomalies_cp_insee set libelle2 = 'insee ign-lp incoherent' where co_insee_lp <> code_insee;

update housenumber h set co_postal = null from housenumber_cp_error h2 where h.ign is not null and h.ign <> '' and h.ign = h2.ign;
update housenumber h set co_postal = null from housenumber_cp_error h2 where h.co_postal is not null and h.laposte is not null and h.laposte <> '' and h.laposte = h2.laposte ;

-- ajout d'un hn null pour chaque groupe laposte pour stocker le cea des voies poste
INSERT INTO housenumber (group_laposte, laposte, co_postal, code_insee, lb_l5, source_init)
SELECT r.co_voie, r.cea, r.co_postal, r.co_insee, r.lb_l5, 'LAPOSTE' from ran_group r 
 ;
--where co_insee like '94%';

-------------- TODO 
-- ajout ancestor ign vide
ALTER TABLE housenumber ADD COLUMN ancestor_ign varchar;


---------------------------------------------------------------------------------
-- REGROUPEMENT DES POSITIONS DANS UNE MËME TABLE
DROP TABLE IF EXISTS position;

-- insertion des positions ign sauf les kind unkown (centre commune)
-- au passage on tronque les coordonnées à 6 chiffres après la virgule ( => 1 dm au max environ)
CREATE TABLE position AS SELECT cia,round(lon::numeric,6) as lon,round(lat::numeric,6) as lat,id as ign,id_hn as housenumber_ign,kind,positioning, designation_de_l_entree as name, 'IGN (2018)'::varchar AS source_init FROM ign_position WHERE kind <> 'unknown' and indice_de_positionnement <> '6';

-- Insertion dans la table position des positions dgfip
INSERT INTO position(cia,lon,lat,kind,positioning,source_init) SELECT d.cia, round(d.lon::numeric,6), round(d.lat::numeric,6), CASE WHEN position_type = 'parcel' THEN 'parcel' ELSE 'entrance' END,'other', 'DGFIP/ETALAB (2018)' FROM dgfip_housenumbers d where position_type is not null
;
--AND insee_com like '94%';

CREATE INDEX idx_position_cia ON position(cia);
CREATE INDEX idx_position_ign ON position(ign);
CREATE INDEX idx_position_housenumber_ign ON position(housenumber_ign);

-- on rabbat le code insee de hn
DROP TABLE IF EXISTS position_temp;
CREATE TABLE position_temp AS SELECT p.*,h1.code_insee as insee1,h2.code_insee as insee2 FROM position p
LEFT JOIN housenumber h1 ON (p.cia = h1.cia)
LEFT JOIN housenumber h2 ON (p.housenumber_ign = h2.ign)
WHERE (h1.cia is not null and h1.cia <> '') OR
(h2.ign is not null and h2.ign <> '');
DROP TABLE position;
ALTER TABLE position_temp RENAME TO position;

-- marquage/suppression des hn IGN pointant vers des groupes ign sans nom
delete from position p using ign_housenumber_sans_nom h where p.housenumber_ign = h.ign and p.ign is not null and p.ign <> '' and h.ign is not null;


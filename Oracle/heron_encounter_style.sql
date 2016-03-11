/** heron_encounter_style -- apply HERON / KUMC / GPC encounter conventions

copyright (c) 2016 University of Kansas Medical Center
availble under the i2b2 Software License (aka MPL?)

*/

/** Index patid, encounterid in hopes of speeding up exploration.

alter session set current_schema = pcornet_cdm;

create unique index demographic_patid on demographic (patid);
create unique index encounter_id on encounter (encounterid);

create index encounter_patid on encounter (patid);
create index diagnosis_patid on diagnosis (patid);
create index diagnosis_encid on diagnosis (encounterid);
create index procedures_patid on procedures (patid);
create index procedures_encid on procedures (encounterid);
create index vital_patid on vital (patid);
 */


/** get length_of_stay, visit end_date from fact table

TODO: push this back into HERON ETL
*/
merge into "&&i2b2_data_schema".visit_dimension vd
using (
  select obs.encounter_num, obs.patient_num
       , obs.nval_num length_of_stay
       , obs.end_date
  from "&&i2b2_data_schema".observation_fact obs
  where obs.concept_cd = 'UHC|LOS:1'  -- TODO: parameterize
) obs
on (  obs.encounter_num = vd.encounter_num
    and obs.patient_num = vd.patient_num)
when matched then update
 set vd.length_of_stay = obs.length_of_stay
         , vd.end_date = obs.end_date
;
-- 194,328 rows merged.


merge into encounter pe
using "&&i2b2_data_schema".visit_dimension vd
   on ( pe.encounterid = vd.encounter_num
        and vd.end_date is not null)
when matched then update set pe.discharge_date = vd.end_date;
-- 165,292 rows merged.


/* Check that we have encounter.discharge_date for selected visit types.

"Discharge date. Should be populated for all
Inpatient Hospital Stay (IP) and Non-Acute
Institutional Stay (IS) encounter types."
 -- PCORnet CDM v3
*/
with enc_agg as (
  select count(*) enc_qty from encounter
  where enc_type in ('IP', 'IS')
  )
select count(*), round(count(*) / enc_qty * 100, 1) pct
from encounter cross join enc_agg
where enc_type in ('IP', 'IS')
and discharge_date is null
group by enc_qty
;



/** TODO: chase down ~80% unknown enc_type */
with enc_agg as (
select count(*) qty from encounter)
select count(*) encounter_qty
     , round(count(*) / enc_agg.qty * 100, 1) pct
     , enc_type
from encounter enc
cross join enc_agg
where exists (
  select admit_date from diagnosis dx where enc.patid = dx.patid)
or exists (
  select admit_date from procedures px where enc.patid = px.patid)
group by enc_type, enc_agg.qty
;

/* TODO: get encounter type from source system? */
select count(*), sourcesystem_cd
from nightherondata.visit_dimension
group by sourcesystem_cd;
*/

/* TODO: get encounter type from place of service? */
select obs.encounter_num, obs.patient_num, obs.start_date, obs.end_date
     , con.concept_cd, con.name_char place_of_service
     , obs.sourcesystem_cd
from "&&i2b2_data_schema".observation_fact obs
join "&&i2b2_data_schema".concept_dimension con on con.concept_cd = obs.concept_cd
join "&&i2b2_data_schema".visit_dimension v on v.encounter_num = obs.encounter_num
where con.concept_path like '\i2b2\Visit Details\Place of Service (IDX)\%'
and v.inout_cd = 'OT'
;


/* Update the visit dimension to populate the inout_cd with the appropriate 
PCORNet encounter type codes based on data in the observation_fact.

The pcornet_mapping table contains columns that translate the PCORNet paths to
local paths.

Example:
pcori_path,local_path
\PCORI\ENCOUNTER\ENC_TYPE\AV\,\i2b2\Visit Details\ENC_TYPE\AV\
*/ 
select * from pcornet_mapping pm where 1=0;

whenever sqlerror continue;
drop table enc_type;
whenever sqlerror exit;

/* explore encounter mapping: where do our encounters come from? */
select count(*), count(distinct encounter_num), encounter_ide_source
from "&&i2b2_data_schema".encounter_mapping
group by encounter_ide_source
order by 1 desc
;

select min(encounter_num), encounter_ide_source
from "&&i2b2_data_schema".encounter_mapping
group by encounter_ide_source
order by 1
;


create table enc_type as
with
enc_type_codes as (
  select 
    pm.pcori_path, replace(substr(pm.pcori_path, instr(pm.pcori_path, '\', -2)), '\', '') pcori_code, pm.local_path, cd.concept_cd
  from pcornet_mapping pm 
  join "&&i2b2_data_schema".concept_dimension cd on cd.concept_path like pm.local_path || '%'
  where pm.pcori_path like '\PCORI\ENCOUNTER\ENC_TYPE\%'
  )
-- TODO: Consider investigating why we have multiple encounter types for a single encounter
select obs.encounter_num, max(et.pcori_code) pcori_code
from "&&i2b2_data_schema".observation_fact obs
join enc_type_codes et on et.concept_cd = obs.concept_cd
group by obs.encounter_num
;

create index enc_type_codes_encnum_idx on enc_type(encounter_num);

update "&&i2b2_data_schema".visit_dimension vd
set inout_cd = coalesce((
  select et.pcori_code from enc_type et
  where vd.encounter_num = et.encounter_num
  ), 'UN');

-- Make sure the update went as expected
select case when count(*) > 0 then 1/0 else 1 end inout_cd_update_match from (
  select * from (
    select vd.inout_cd vd_code, et.pcori_code et_code
    from "&&i2b2_data_schema".visit_dimension vd
    left join enc_type et on et.encounter_num = vd.encounter_num
    )
  where vd_code != vd_code and not (vd_code = 'UN' and vd_code is null)
  );

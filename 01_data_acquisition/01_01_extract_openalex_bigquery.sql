DECLARE start_year INT64 DEFAULT 1995;
DECLARE end_year INT64 DEFAULT 2025;

DECLARE target_field_ids ARRAY<INT64> DEFAULT [
  11,
  16,
  19,
  25,
  27,
  31
];

CREATE TEMP FUNCTION openalex_numeric_id(openalex_id STRING)
RETURNS INT64
AS (
  SAFE_CAST(REGEXP_EXTRACT(openalex_id, r'(\d+)$') AS INT64)
);


-- ============================================================
-- Create the output dataset
-- ============================================================

CREATE SCHEMA IF NOT EXISTS
  `gen-lang-client-0046086839.openalex_analysis`
OPTIONS (
  location = 'US',
  description = 'OpenAlex data for the core-periphery science project'
);


-- ============================================================
-- 1. Create the main staging table
-- This is the expensive scan of works_20260203.
-- IF NOT EXISTS prevents accidental repeated scans.
-- ============================================================

CREATE TABLE IF NOT EXISTS
  `gen-lang-client-0046086839.openalex_analysis.works_stage`
PARTITION BY RANGE_BUCKET(
  publication_year,
  GENERATE_ARRAY(1900, 2031, 1)
)
CLUSTER BY primary_field_id, source_id
OPTIONS (
  description = 'Selected OpenAlex works with nested topics, authorships, and references'
)
AS

SELECT
  w.id AS work_id,
  w.ids.openalex AS openalex_id,
  w.doi,
  w.ids.pmid AS pmid,
  w.ids.mag AS mag_id,

  w.title,
  w.display_name,
  w.abstract,
  w.abstract_inverted_index,
  w.has_abstract,

  (
    w.title IS NOT NULL
    AND w.abstract IS NOT NULL
    AND LENGTH(TRIM(w.abstract)) > 0
  ) AS has_usable_text,

  w.publication_date,
  w.publication_year,
  w.type AS work_type,
  w.language,

  w.is_retracted,
  w.is_paratext,
  w.is_xpac,

  w.authors_count AS authors_count_reported,
  ARRAY_LENGTH(w.authorships) AS authorship_count_observed,

  (
    w.authors_count = ARRAY_LENGTH(w.authorships)
  ) AS authorship_complete,

  w.countries_distinct_count,
  w.institutions_distinct_count,

  w.corresponding_author_ids,
  w.corresponding_institution_ids,

  w.authorships,

  w.institutions AS work_institution_ids,

  w.primary_topic.id AS primary_topic_id,
  w.primary_topic.display_name AS primary_topic_name,
  w.primary_topic.score AS primary_topic_score,

  w.primary_topic.subfield.id AS primary_subfield_id,
  w.primary_topic.subfield.display_name AS primary_subfield_name,

  openalex_numeric_id(w.primary_topic.field.id) AS primary_field_id,
  w.primary_topic.field.id AS primary_field_openalex_id,
  w.primary_topic.field.display_name AS primary_field_name,

  w.primary_topic.domain.id AS primary_domain_id,
  w.primary_topic.domain.display_name AS primary_domain_name,

  w.topics,
  w.keywords,
  w.concepts,
  w.mesh,

  w.sustainable_development_goals,
  w.funders,
  w.awards,

  w.cited_by_count AS cited_by_count_snapshot,
  w.counts_by_year AS citation_counts_by_year,
  w.fwci AS fwci_snapshot,

  w.citation_normalized_percentile.value
    AS citation_percentile_snapshot,

  w.citation_normalized_percentile.is_in_top_1_percent
    AS is_top_1_percent_snapshot,

  w.citation_normalized_percentile.is_in_top_10_percent
    AS is_top_10_percent_snapshot,

  w.cited_by_percentile_year.min
    AS cited_by_percentile_year_min,

  w.cited_by_percentile_year.max
    AS cited_by_percentile_year_max,

  w.referenced_works,
  w.referenced_works_count,
  w.related_works,

  w.primary_location.source.id AS source_id,
  w.primary_location.source.display_name AS source_name,
  w.primary_location.source.type AS source_type,
  w.primary_location.source.issn_l AS source_issn_l,
  w.primary_location.source.issn AS source_issn,

  w.primary_location.source.host_organization
    AS source_host_organization_id,

  w.primary_location.source.host_organization_name
    AS source_host_organization_name,

  w.primary_location.source.host_organization_lineage
    AS source_host_organization_lineage,

  w.primary_location.source.host_organization_lineage_names
    AS source_host_organization_lineage_names,

  w.primary_location.source.is_oa AS source_is_oa,
  w.primary_location.source.is_in_doaj AS source_is_in_doaj,
  w.primary_location.source.is_core AS source_is_core,

  w.primary_location.raw_source_name,
  w.primary_location.version AS publication_version,
  w.primary_location.is_oa AS primary_location_is_oa,
  w.primary_location.is_accepted AS primary_location_is_accepted,
  w.primary_location.is_published AS primary_location_is_published,
  w.primary_location.license AS primary_location_license,
  w.primary_location.landing_page_url,
  w.primary_location.pdf_url,

  w.open_access.is_oa,
  w.open_access.oa_status,
  w.open_access.oa_url,
  w.open_access.any_repository_has_fulltext,

  w.has_fulltext,
  w.has_content.pdf AS has_pdf,
  w.has_content.grobid_xml AS has_grobid_xml,

  w.indexed_in,

  w.apc_paid.currency AS apc_paid_currency,
  w.apc_paid.value AS apc_paid_value,
  w.apc_paid.value_usd AS apc_paid_value_usd,

  w.biblio.volume,
  w.biblio.issue,
  w.biblio.first_page,
  w.biblio.last_page,

  w.created_date,
  w.updated_date

FROM `nber-i3.openalex.works_20260203` AS w

WHERE w.publication_year BETWEEN start_year AND end_year

  AND EXISTS (
    SELECT 1
    FROM UNNEST(w.topics) AS topic
    WHERE openalex_numeric_id(topic.field.id)
      IN UNNEST(target_field_ids)
  );


-- ============================================================
-- 2. Create the text table for SPECTER2 embeddings
-- ============================================================

CREATE OR REPLACE TABLE
  `gen-lang-client-0046086839.openalex_analysis.work_text`
PARTITION BY RANGE_BUCKET(
  publication_year,
  GENERATE_ARRAY(1900, 2031, 1)
)
CLUSTER BY work_id
OPTIONS (
  description = 'Titles and abstracts for document embeddings'
)
AS

SELECT
  work_id,
  doi,
  publication_year,
  publication_date,
  title,
  abstract,
  work_type,
  language,
  is_retracted,
  is_paratext
FROM `gen-lang-client-0046086839.openalex_analysis.works_stage`
WHERE has_usable_text
  AND is_retracted IS NOT TRUE
  AND is_paratext IS NOT TRUE;


-- ============================================================
-- 3. Create one row per work-topic
-- Includes all four classification levels
-- ============================================================

CREATE OR REPLACE TABLE
  `gen-lang-client-0046086839.openalex_analysis.work_topic`
PARTITION BY RANGE_BUCKET(
  publication_year,
  GENERATE_ARRAY(1900, 2031, 1)
)
CLUSTER BY field_id, subfield_id, topic_id
OPTIONS (
  description = 'One row per work-topic assignment'
)
AS

SELECT
  works.work_id,
  works.publication_year,

  topic.id AS topic_id,
  topic.display_name AS topic_name,
  topic.score AS topic_score,

  topic.subfield.id AS subfield_id,
  topic.subfield.display_name AS subfield_name,

  openalex_numeric_id(topic.field.id) AS field_id,
  topic.field.id AS field_openalex_id,
  topic.field.display_name AS field_name,

  topic.domain.id AS domain_id,
  topic.domain.display_name AS domain_name,

  topic.id = works.primary_topic_id AS is_primary_topic,

  openalex_numeric_id(topic.field.id)
    IN UNNEST(target_field_ids)
    AS is_target_field

FROM `gen-lang-client-0046086839.openalex_analysis.works_stage` AS works
CROSS JOIN UNNEST(works.topics) AS topic;


-- ============================================================
-- 4. Create one row per work-field
-- A work appears once in each assigned target field
-- ============================================================

CREATE OR REPLACE TABLE
  `gen-lang-client-0046086839.openalex_analysis.work_field`
PARTITION BY RANGE_BUCKET(
  publication_year,
  GENERATE_ARRAY(1900, 2031, 1)
)
CLUSTER BY field_id, work_id
OPTIONS (
  description = 'One row per work and target OpenAlex field'
)
AS

SELECT
  work_id,
  publication_year,
  field_id,
  field_openalex_id,
  field_name,

  CASE field_id
    WHEN 11 THEN 'biology'
    WHEN 16 THEN 'chemistry'
    WHEN 19 THEN 'geology'
    WHEN 25 THEN 'materials_science'
    WHEN 27 THEN 'medicine'
    WHEN 31 THEN 'physics'
  END AS analytic_field,

  topic_id AS representative_topic_id,
  topic_name AS representative_topic_name,
  topic_score AS representative_topic_score,

  subfield_id AS representative_subfield_id,
  subfield_name AS representative_subfield_name,

  domain_id,
  domain_name

FROM `gen-lang-client-0046086839.openalex_analysis.work_topic`

WHERE field_id IN UNNEST(target_field_ids)

QUALIFY ROW_NUMBER() OVER (
  PARTITION BY work_id, field_id
  ORDER BY
    topic_score DESC,
    topic_id
) = 1;


-- ============================================================
-- 5. Create one row per work-author
-- ============================================================

CREATE OR REPLACE TABLE
  `gen-lang-client-0046086839.openalex_analysis.work_authorship`
PARTITION BY RANGE_BUCKET(
  publication_year,
  GENERATE_ARRAY(1900, 2031, 1)
)
CLUSTER BY author_id, work_id
OPTIONS (
  description = 'One row per work-author relationship'
)
AS

SELECT
  works.work_id,
  works.publication_year,

  authorship.author.id AS author_id,
  authorship.author.display_name AS author_name,
  authorship.author.orcid AS author_orcid,

  author_offset + 1 AS authorship_position,

  authorship.is_corresponding,

  authorship.raw_author_name,
  authorship.raw_affiliation_strings,
  authorship.affiliations,
  authorship.countries,

  ARRAY_LENGTH(authorship.institutions)
    AS authorship_institution_count,

  works.authors_count_reported,
  works.authorship_count_observed,
  works.authorship_complete

FROM `gen-lang-client-0046086839.openalex_analysis.works_stage` AS works
CROSS JOIN UNNEST(works.authorships) AS authorship
WITH OFFSET AS author_offset

WHERE authorship.author.id IS NOT NULL;


-- ============================================================
-- 6. Create one row per work-author-institution
-- Historical affiliation comes from the work authorship
-- ============================================================

CREATE OR REPLACE TABLE
  `gen-lang-client-0046086839.openalex_analysis.work_author_institution`
PARTITION BY RANGE_BUCKET(
  publication_year,
  GENERATE_ARRAY(1900, 2031, 1)
)
CLUSTER BY author_id, institution_id, work_id
OPTIONS (
  description = 'Work-level author institution affiliations'
)
AS

SELECT
  works.work_id,
  works.publication_year,

  authorship.author.id AS author_id,
  authorship.author.display_name AS author_name,
  authorship.author.orcid AS author_orcid,

  authorship.is_corresponding,

  institution.id AS institution_id,
  institution.display_name AS institution_name,
  institution.ror AS institution_ror,
  institution.country_code AS institution_country_code,
  institution.type AS institution_type,
  institution.lineage AS institution_lineage,

  authorship.countries AS authorship_countries,
  authorship.raw_author_name,
  authorship.raw_affiliation_strings,
  authorship.affiliations,

  works.authorship_complete

FROM `gen-lang-client-0046086839.openalex_analysis.works_stage` AS works
CROSS JOIN UNNEST(works.authorships) AS authorship
LEFT JOIN UNNEST(authorship.institutions) AS institution
  ON TRUE

WHERE authorship.author.id IS NOT NULL;


-- ============================================================
-- 7. Create one row per work-keyword
-- ============================================================

CREATE OR REPLACE TABLE
  `gen-lang-client-0046086839.openalex_analysis.work_keyword`
PARTITION BY RANGE_BUCKET(
  publication_year,
  GENERATE_ARRAY(1900, 2031, 1)
)
CLUSTER BY keyword_id, work_id
OPTIONS (
  description = 'One row per OpenAlex work keyword'
)
AS

SELECT
  works.work_id,
  works.publication_year,

  keyword.id AS keyword_id,
  keyword.display_name AS keyword_name,
  keyword.score AS keyword_score

FROM `gen-lang-client-0046086839.openalex_analysis.works_stage` AS works
CROSS JOIN UNNEST(works.keywords) AS keyword;


-- ============================================================
-- 8. Create one row per citing-cited work pair
-- ============================================================

CREATE OR REPLACE TABLE
  `gen-lang-client-0046086839.openalex_analysis.work_reference`
PARTITION BY RANGE_BUCKET(
  citing_year,
  GENERATE_ARRAY(1900, 2031, 1)
)
CLUSTER BY cited_work_id, citing_work_id
OPTIONS (
  description = 'Directed OpenAlex reference edges'
)
AS

SELECT
  works.work_id AS citing_work_id,
  works.publication_year AS citing_year,
  cited_work_id

FROM `gen-lang-client-0046086839.openalex_analysis.works_stage` AS works
CROSS JOIN UNNEST(works.referenced_works) AS cited_work_id;


-- ============================================================
-- 9. Create the selected journal and source dimension
-- Includes all source metrics from sources_20260203
-- ============================================================

CREATE OR REPLACE TABLE
  `gen-lang-client-0046086839.openalex_analysis.source_dim`
CLUSTER BY id
OPTIONS (
  description = 'OpenAlex source metadata for selected works'
)
AS

SELECT
  source.*

FROM `nber-i3.openalex.sources_20260203` AS source

INNER JOIN (
  SELECT DISTINCT source_id
  FROM `gen-lang-client-0046086839.openalex_analysis.works_stage`
  WHERE source_id IS NOT NULL
) AS selected_sources

  ON source.id = selected_sources.source_id;


-- ============================================================
-- 10. Create the selected author dimension
-- Includes author summary statistics and affiliation history
-- ============================================================

CREATE OR REPLACE TABLE
  `gen-lang-client-0046086839.openalex_analysis.author_dim`
CLUSTER BY id
OPTIONS (
  description = 'OpenAlex author metadata for selected works'
)
AS

SELECT
  author.*

FROM `nber-i3.openalex.authors_20260203` AS author

INNER JOIN (
  SELECT DISTINCT author_id
  FROM `gen-lang-client-0046086839.openalex_analysis.work_authorship`
  WHERE author_id IS NOT NULL
) AS selected_authors

  ON author.id = selected_authors.author_id;


-- ============================================================
-- 11. Create the selected institution dimension
-- Includes institution geography, type, lineage, and metrics
-- ============================================================

CREATE OR REPLACE TABLE
  `gen-lang-client-0046086839.openalex_analysis.institution_dim`
CLUSTER BY id
OPTIONS (
  description = 'OpenAlex institution metadata for selected works'
)
AS

SELECT
  institution.*

FROM `nber-i3.openalex.institutions_20260203` AS institution

INNER JOIN (
  SELECT DISTINCT institution_id
  FROM `gen-lang-client-0046086839.openalex_analysis.work_author_institution`
  WHERE institution_id IS NOT NULL
) AS selected_institutions

  ON institution.id = selected_institutions.institution_id;


-- ============================================================
-- 12. Create field-year coverage statistics
-- ============================================================

CREATE OR REPLACE TABLE
  `gen-lang-client-0046086839.openalex_analysis.coverage_by_field_year`
PARTITION BY RANGE_BUCKET(
  publication_year,
  GENERATE_ARRAY(1900, 2031, 1)
)
CLUSTER BY field_id
OPTIONS (
  description = 'Coverage statistics by OpenAlex field and publication year'
)
AS

SELECT
  fields.field_id,
  fields.field_name,
  fields.analytic_field,
  fields.publication_year,

  COUNT(*) AS n_works,

  COUNTIF(
    works.title IS NOT NULL
  ) AS n_with_title,

  COUNTIF(
    works.abstract IS NOT NULL
    AND LENGTH(TRIM(works.abstract)) > 0
  ) AS n_with_abstract,

  COUNTIF(
    works.has_usable_text
  ) AS n_with_usable_text,

  COUNTIF(
    works.authorship_count_observed > 0
  ) AS n_with_authorships,

  COUNTIF(
    works.authorship_complete
  ) AS n_with_complete_authorships,

  COUNTIF(
    works.institutions_distinct_count > 0
  ) AS n_with_institutions,

  COUNTIF(
    works.source_id IS NOT NULL
  ) AS n_with_source,

  COUNTIF(
    works.referenced_works_count > 0
  ) AS n_with_references,

  COUNTIF(
    works.is_retracted
  ) AS n_retracted,

  COUNTIF(
    works.is_paratext
  ) AS n_paratext,

  AVG(works.authors_count_reported)
    AS mean_reported_authors,

  AVG(works.referenced_works_count)
    AS mean_reference_count,

  AVG(works.cited_by_count_snapshot)
    AS mean_cited_by_count_snapshot

FROM `gen-lang-client-0046086839.openalex_analysis.work_field` AS fields

INNER JOIN
  `gen-lang-client-0046086839.openalex_analysis.works_stage` AS works

  ON fields.work_id = works.work_id
  AND fields.publication_year = works.publication_year

GROUP BY
  fields.field_id,
  fields.field_name,
  fields.analytic_field,
  fields.publication_year;


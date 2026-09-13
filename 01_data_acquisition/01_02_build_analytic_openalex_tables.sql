-- ============================================================
-- 1. Final analytic article sample, including 2025
-- ============================================================

CREATE OR REPLACE TABLE
  `gen-lang-client-0046086839.openalex_analysis.analytic_work`
PARTITION BY RANGE_BUCKET(
  publication_year,
  GENERATE_ARRAY(1900, 2031, 1)
)
CLUSTER BY primary_field_id, work_id
OPTIONS (
  description = 'Article sample from 1995 through 2025 for network and semantic analyses'
)
AS

SELECT
  *

FROM
  `gen-lang-client-0046086839.openalex_analysis.works_stage`

WHERE publication_year BETWEEN 1995 AND 2025

  AND work_type = 'article'

  AND title IS NOT NULL

  AND abstract IS NOT NULL

  AND LENGTH(TRIM(abstract)) > 0

  AND authorship_count_observed > 0

  AND EXISTS (
    SELECT 1
    FROM UNNEST(authorships) AS authorship
    WHERE authorship.author.id IS NOT NULL
  )

  AND is_retracted IS NOT TRUE

  AND is_paratext IS NOT TRUE;


-- ============================================================
-- 2. Work-field assignments
-- ============================================================

CREATE OR REPLACE TABLE
  `gen-lang-client-0046086839.openalex_analysis.analytic_work_field`
PARTITION BY RANGE_BUCKET(
  publication_year,
  GENERATE_ARRAY(1900, 2031, 1)
)
CLUSTER BY field_id, work_id
OPTIONS (
  description = 'Target-field assignments for analytic articles from 1995 through 2025'
)
AS

SELECT
  field.*

FROM
  `gen-lang-client-0046086839.openalex_analysis.work_field`
    AS field

INNER JOIN
  `gen-lang-client-0046086839.openalex_analysis.analytic_work`
    AS work

  ON field.work_id = work.work_id
  AND field.publication_year = work.publication_year;


-- ============================================================
-- 3. Work-author records
-- ============================================================

CREATE OR REPLACE TABLE
  `gen-lang-client-0046086839.openalex_analysis.analytic_work_authorship`
PARTITION BY RANGE_BUCKET(
  publication_year,
  GENERATE_ARRAY(1900, 2031, 1)
)
CLUSTER BY author_id, work_id
OPTIONS (
  description = 'Author records for analytic articles from 1995 through 2025'
)
AS

SELECT
  authorship.*

FROM
  `gen-lang-client-0046086839.openalex_analysis.work_authorship`
    AS authorship

INNER JOIN
  `gen-lang-client-0046086839.openalex_analysis.analytic_work`
    AS work

  ON authorship.work_id = work.work_id
  AND authorship.publication_year = work.publication_year;


-- ============================================================
-- 4. Work-author-institution records
-- ============================================================

CREATE OR REPLACE TABLE
  `gen-lang-client-0046086839.openalex_analysis.analytic_work_author_institution`
PARTITION BY RANGE_BUCKET(
  publication_year,
  GENERATE_ARRAY(1900, 2031, 1)
)
CLUSTER BY author_id, institution_id, work_id
OPTIONS (
  description = 'Historical author affiliations for analytic articles'
)
AS

SELECT
  affiliation.*

FROM
  `gen-lang-client-0046086839.openalex_analysis.work_author_institution`
    AS affiliation

INNER JOIN
  `gen-lang-client-0046086839.openalex_analysis.analytic_work`
    AS work

  ON affiliation.work_id = work.work_id
  AND affiliation.publication_year = work.publication_year;


-- ============================================================
-- 5. Topic records
-- ============================================================

CREATE OR REPLACE TABLE
  `gen-lang-client-0046086839.openalex_analysis.analytic_work_topic`
PARTITION BY RANGE_BUCKET(
  publication_year,
  GENERATE_ARRAY(1900, 2031, 1)
)
CLUSTER BY field_id, subfield_id, topic_id
OPTIONS (
  description = 'Topic assignments for analytic articles'
)
AS

SELECT
  topic.*

FROM
  `gen-lang-client-0046086839.openalex_analysis.work_topic`
    AS topic

INNER JOIN
  `gen-lang-client-0046086839.openalex_analysis.analytic_work`
    AS work

  ON topic.work_id = work.work_id
  AND topic.publication_year = work.publication_year;


-- ============================================================
-- 6. Outgoing reference records
-- ============================================================

CREATE OR REPLACE TABLE
  `gen-lang-client-0046086839.openalex_analysis.analytic_work_reference`
PARTITION BY RANGE_BUCKET(
  citing_year,
  GENERATE_ARRAY(1900, 2031, 1)
)
CLUSTER BY cited_work_id, citing_work_id
OPTIONS (
  description = 'Outgoing references from analytic articles'
)
AS

SELECT
  reference.*

FROM
  `gen-lang-client-0046086839.openalex_analysis.work_reference`
    AS reference

INNER JOIN
  `gen-lang-client-0046086839.openalex_analysis.analytic_work`
    AS work

  ON reference.citing_work_id = work.work_id
  AND reference.citing_year = work.publication_year;


-- ============================================================
-- 7. Text input for SPECTER2
-- ============================================================

CREATE OR REPLACE TABLE
  `gen-lang-client-0046086839.openalex_analysis.analytic_work_text`
PARTITION BY RANGE_BUCKET(
  publication_year,
  GENERATE_ARRAY(1900, 2031, 1)
)
CLUSTER BY work_id
OPTIONS (
  description = 'Title and abstract input for SPECTER2, including 2025'
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
  language

FROM
  `gen-lang-client-0046086839.openalex_analysis.analytic_work`;


-- ============================================================
-- 8. Valid focal years
-- ============================================================

CREATE OR REPLACE TABLE
  `gen-lang-client-0046086839.openalex_analysis.focal_year`
OPTIONS (
  description = 'Focal years with five baseline years and three outcome years'
)
AS

SELECT
  focal_year,

  focal_year - 5 AS baseline_start_year,
  focal_year - 1 AS baseline_end_year,

  focal_year AS outcome_start_year,
  focal_year + 2 AS outcome_end_year

FROM UNNEST(
  GENERATE_ARRAY(2000, 2023)
) AS focal_year;
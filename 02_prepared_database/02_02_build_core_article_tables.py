#!/usr/bin/env python3
"""Build six-field paper outcomes and fixed-effect identifiers."""

import duckdb


DB_PATH = "/private/tmp/journal_structure_six.duckdb"
WORKS_PATH = "/Volumes/Extreme SSD/openalex_20260203/analytic_work/*.parquet"


connection = duckdb.connect(DB_PATH)
connection.execute("SET threads=8")
connection.execute("SET memory_limit='32GB'")
connection.execute("SET temp_directory='/private/tmp/duckdb_six_tmp'")
connection.execute("SET preserve_insertion_order=FALSE")

connection.execute(
    """
    CREATE OR REPLACE TABLE six_base AS
    SELECT
        work_id,
        publication_date,
        publication_year,
        CASE primary_field_id
            WHEN 11 THEN 'biology'
            WHEN 16 THEN 'chemistry'
            WHEN 19 THEN 'geology'
            WHEN 25 THEN 'materials_science'
            WHEN 27 THEN 'medicine'
            WHEN 31 THEN 'physics'
        END AS analytic_field,
        primary_topic_id AS topic_id,
        primary_topic_name AS topic_name,
        source_id,
        source_name,
        language,
        LN(1 + COALESCE(authors_count_reported, 0)) AS log_authors,
        CAST(COALESCE(is_oa, FALSE) AS DOUBLE) AS oa_value,
        CASE WHEN sjr.source_id IS NULL THEN FALSE ELSE TRUE END AS sjr_matched,
        COALESCE(LIST_SUM(LIST_TRANSFORM(
            citation_counts_by_year,
            item -> CASE WHEN item.year BETWEEN publication_year
                                             AND publication_year + 1
                         THEN item.cited_by_count ELSE 0 END
        )), 0) AS citations_2y,
        COALESCE(LIST_SUM(LIST_TRANSFORM(
            citation_counts_by_year,
            item -> CASE WHEN item.year BETWEEN publication_year
                                             AND publication_year + 2
                         THEN item.cited_by_count ELSE 0 END
        )), 0) AS citations_3y,
        COALESCE(LIST_SUM(LIST_TRANSFORM(
            citation_counts_by_year,
            item -> CASE WHEN item.year BETWEEN publication_year
                                             AND publication_year + 4
                         THEN item.cited_by_count ELSE 0 END
        )), 0) AS citations_5y,
        LIST_MIN(LIST_TRANSFORM(LIST_FILTER(
            citation_counts_by_year,
            item -> item.cited_by_count > 0
                 AND item.year >= publication_year
        ), item -> item.year)) AS first_citation_year
    FROM read_parquet(?) AS works
    LEFT JOIN sjr_sources AS sjr USING (source_id)
    WHERE publication_year BETWEEN 2015 AND 2023
      AND primary_field_id IN (11, 16, 19, 25, 27, 31)
      AND work_type = 'article'
      AND referenced_works_count > 0
      AND source_type = 'journal'
      AND source_id IS NOT NULL
      AND primary_topic_id IS NOT NULL
    """,
    [WORKS_PATH],
)

connection.execute(
    """
    CREATE OR REPLACE TABLE corresponding_author AS
    WITH ranked AS (
        SELECT
            authorship.work_id,
            authorship.author_id,
            authorship.authorship_position,
            COUNT(*) OVER (PARTITION BY authorship.work_id) AS n_corresponding,
            ROW_NUMBER() OVER (
                PARTITION BY authorship.work_id
                ORDER BY authorship.authorship_position, authorship.author_id
            ) AS choice_rank
        FROM read_parquet(
            '/Volumes/Extreme SSD/openalex_20260203/analytic_work_authorship/*.parquet'
        ) AS authorship
        SEMI JOIN six_base AS base USING (work_id)
        WHERE authorship.is_corresponding = TRUE
          AND authorship.author_id IS NOT NULL
    )
    SELECT work_id, author_id, n_corresponding
    FROM ranked
    WHERE choice_rank = 1
    """
)

connection.execute(
    """
    CREATE OR REPLACE TABLE corresponding_institution AS
    WITH ranked AS (
        SELECT
            institution.work_id,
            institution.author_id,
            institution.institution_id,
            COUNT(*) OVER (
                PARTITION BY institution.work_id, institution.author_id
            ) AS n_corresponding_institutions,
            ROW_NUMBER() OVER (
                PARTITION BY institution.work_id, institution.author_id
                ORDER BY institution.institution_id
            ) AS choice_rank
        FROM read_parquet(
            '/Volumes/Extreme SSD/openalex_20260203/analytic_work_author_institution/*.parquet'
        ) AS institution
        INNER JOIN corresponding_author AS author
          ON institution.work_id = author.work_id
         AND institution.author_id = author.author_id
        WHERE institution.is_corresponding = TRUE
          AND institution.institution_id IS NOT NULL
    )
    SELECT work_id, author_id, institution_id, n_corresponding_institutions
    FROM ranked
    WHERE choice_rank = 1
    """
)

connection.execute(
    """
    CREATE OR REPLACE TABLE paper_universes AS
    SELECT 'full' AS universe, * FROM six_base
    UNION ALL
    SELECT 'scimago' AS universe, * FROM six_base WHERE sjr_matched
    """
)

connection.execute(
    """
    CREATE OR REPLACE TABLE journal_exposure AS
    WITH journal_counts AS (
        SELECT universe, analytic_field, publication_year,
               topic_id, source_id, COUNT(*) AS journal_articles
        FROM paper_universes
        GROUP BY ALL
    ),
    journal_shares AS (
        SELECT *, journal_articles * 1.0 /
            SUM(journal_articles) OVER cell AS journal_share
        FROM journal_counts
        WINDOW cell AS (PARTITION BY universe, analytic_field,
                                     publication_year, topic_id)
    )
    SELECT universe, analytic_field, publication_year, topic_id,
           SUM(journal_articles) AS cell_n,
           COUNT(*) AS journal_count,
           1.0 / SUM(POWER(journal_share, 2)) AS eff_j,
           LN(1.0 / SUM(POWER(journal_share, 2))) AS log_eff_j
    FROM journal_shares
    GROUP BY ALL
    """
)

connection.execute(
    """
    CREATE OR REPLACE TABLE analysis_articles AS
    WITH standardized AS (
        SELECT
            papers.*,
            LN(1 + citations_2y) AS log_citations_2y,
            LN(1 + citations_3y) AS log_citations_3y,
            LN(1 + citations_5y) AS log_citations_5y,
            CASE
                WHEN STDDEV_SAMP(LN(1 + citations_3y)) OVER field_year > 0
                THEN (LN(1 + citations_3y) -
                      AVG(LN(1 + citations_3y)) OVER field_year) /
                     STDDEV_SAMP(LN(1 + citations_3y)) OVER field_year
                ELSE 0
            END AS citation_z_3y,
            CAST(first_citation_year IS NOT NULL AND
                 first_citation_year <= publication_year AS DOUBLE)
                AS cited_in_publication_year,
            CAST(first_citation_year IS NOT NULL AND
                 first_citation_year <= publication_year + 1 AS DOUBLE)
                AS cited_within_2y,
            CAST(first_citation_year IS NOT NULL AND
                 first_citation_year <= publication_year + 2 AS DOUBLE)
                AS cited_within_3y,
            CASE WHEN first_citation_year IS NULL OR
                           first_citation_year > publication_year + 2
                 THEN 3
                 ELSE first_citation_year - publication_year END
                AS first_citation_delay_capped_3y
        FROM paper_universes AS papers
        WINDOW field_year AS (
            PARTITION BY universe, analytic_field, publication_year
        )
    ),
    cell_medians AS (
        SELECT universe, analytic_field, publication_year, topic_id,
               MEDIAN(citation_z_3y) AS cell_median_3y
        FROM standardized
        GROUP BY ALL
    )
    SELECT
        standardized.*,
        ABS(standardized.citation_z_3y - medians.cell_median_3y)
            AS citation_abs_dev_3y,
        exposure.cell_n,
        exposure.journal_count,
        exposure.eff_j,
        exposure.log_eff_j,
        author.author_id AS corresponding_author_id,
        institution.institution_id AS corresponding_institution_id,
        author.n_corresponding,
        institution.n_corresponding_institutions,
        analytic_field || '||' || CAST(publication_year AS VARCHAR)
            AS field_year_id
    FROM standardized
    INNER JOIN cell_medians AS medians USING (
        universe, analytic_field, publication_year, topic_id
    )
    INNER JOIN journal_exposure AS exposure USING (
        universe, analytic_field, publication_year, topic_id
    )
    LEFT JOIN corresponding_author AS author USING (work_id)
    LEFT JOIN corresponding_institution AS institution USING (work_id)
    """
)

connection.execute(
    """
    COPY analysis_articles
    TO '/private/tmp/journal_structure_six_analysis_articles.parquet'
    (FORMAT PARQUET, COMPRESSION ZSTD)
    """
)

print(connection.execute(
    """
    SELECT universe, analytic_field,
           COUNT(*) AS papers,
           COUNT(DISTINCT source_id) AS journals,
           AVG(corresponding_author_id IS NOT NULL)::DOUBLE
               AS corresponding_author_coverage,
           AVG(corresponding_institution_id IS NOT NULL)::DOUBLE
               AS corresponding_institution_coverage,
           AVG(n_corresponding > 1)::DOUBLE AS multiple_corresponding_share,
           AVG(n_corresponding_institutions > 1)::DOUBLE
               AS multiple_institution_share
    FROM analysis_articles
    GROUP BY ALL
    ORDER BY universe, analytic_field
    """
).fetchdf().to_string(index=False))

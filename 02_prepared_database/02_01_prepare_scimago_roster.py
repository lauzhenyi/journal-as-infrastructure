#!/usr/bin/env python3
"""Build six-field and SCImago-universe staging tables."""

import duckdb


DB_PATH = "/private/tmp/journal_structure_six.duckdb"
WORKS_PATH = "/Volumes/Extreme SSD/openalex_20260203/analytic_work/*.parquet"
SCIMAGO_PATH = (
    "/Volumes/Extreme SSD/RA/computational_sociology/"
    "scimagojr/scimagojr 20*.csv"
)


connection = duckdb.connect(DB_PATH)
connection.execute("SET threads=8")
connection.execute("SET memory_limit='32GB'")
connection.execute("SET temp_directory='/private/tmp/duckdb_six_tmp'")
connection.execute("SET preserve_insertion_order=FALSE")

connection.execute(
    """
    CREATE OR REPLACE TABLE sjr_issn AS
    WITH raw AS (
        SELECT Issn
        FROM read_csv_auto(
            ?, delim=';', header=TRUE, union_by_name=TRUE,
            ignore_errors=TRUE
        )
    ),
    long AS (
        SELECT UPPER(REGEXP_REPLACE(value, '[^0-9Xx]', '', 'g')) AS issn
        FROM raw, UNNEST(STRING_SPLIT(Issn, ',')) AS item(value)
    )
    SELECT DISTINCT issn
    FROM long
    WHERE LENGTH(issn) = 8
    """,
    [SCIMAGO_PATH],
)

connection.execute(
    """
    CREATE OR REPLACE TABLE six_sources AS
    SELECT
        source_id,
        ANY_VALUE(source_name) AS source_name,
        ANY_VALUE(source_issn_l) AS source_issn_l,
        ANY_VALUE(source_issn) AS source_issn
    FROM read_parquet(?)
    WHERE publication_year BETWEEN 2015 AND 2023
      AND primary_field_id IN (11, 16, 19, 25, 27, 31)
      AND work_type = 'article'
      AND source_type = 'journal'
      AND source_id IS NOT NULL
    GROUP BY source_id
    """,
    [WORKS_PATH],
)

connection.execute(
    """
    CREATE OR REPLACE TABLE sjr_sources AS
    WITH long AS (
        SELECT DISTINCT
            source_id,
            UPPER(REGEXP_REPLACE(value, '[^0-9Xx]', '', 'g')) AS issn
        FROM six_sources,
        UNNEST(
            LIST_DISTINCT(
                LIST_CONCAT(
                    COALESCE(source_issn, []),
                    CASE
                        WHEN source_issn_l IS NULL THEN []
                        ELSE [source_issn_l]
                    END
                )
            )
        ) AS item(value)
    )
    SELECT DISTINCT source_id
    FROM long
    SEMI JOIN sjr_issn USING (issn)
    """
)

print(
    connection.execute(
        """
        SELECT
            (SELECT COUNT(*) FROM sjr_issn) AS scimago_issns,
            (SELECT COUNT(*) FROM six_sources) AS openalex_sources,
            (SELECT COUNT(*) FROM sjr_sources) AS sjr_matched_sources
        """
    ).fetchdf().to_string(index=False)
)

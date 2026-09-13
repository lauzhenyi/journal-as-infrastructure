#!/usr/bin/env python3
"""Build topical, institutional, and geographic follow-on attention breadth."""

from __future__ import annotations

import time

import duckdb


DB_PATH = "/private/tmp/journal_structure_six.duckdb"
WORKS_PATH = "/Volumes/Extreme SSD/openalex_20260203/analytic_work/*.parquet"
INSTITUTIONS_PATH = (
    "/Volumes/Extreme SSD/openalex_20260203/"
    "analytic_work_author_institution/*.parquet"
)


connection = duckdb.connect(DB_PATH)
connection.execute("SET threads=8")
connection.execute("SET memory_limit='32GB'")
connection.execute("SET temp_directory='/private/tmp/duckdb_breadth_tmp'")
connection.execute("SET preserve_insertion_order=FALSE")


def exists(table: str) -> bool:
    """Return whether a persistent table exists."""
    return bool(connection.execute(
        "SELECT COUNT(*) FROM information_schema.tables WHERE table_name = ?",
        [table],
    ).fetchone()[0])


def stage(table: str, query: str) -> None:
    """Create a resumable stage and report elapsed time."""
    if exists(table):
        print(f"Reuse {table}", flush=True)
        return
    started = time.time()
    connection.execute(f"CREATE TABLE {table} AS {query}")
    count = connection.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
    print(f"Built {table}: {count:,} rows in {time.time() - started:.1f}s", flush=True)


stage(
    "citer_intellectual_metadata_six",
    f"""
    SELECT
        works.work_id,
        works.primary_topic_id AS citing_topic_id,
        works.primary_field_id AS citing_field_id,
        works.primary_domain_id AS citing_domain_id
    FROM read_parquet('{WORKS_PATH}') AS works
    SEMI JOIN family_citer_ids_six AS citer USING (work_id)
    """,
)

stage(
    "citer_corresponding_institution_six",
    f"""
    WITH ranked AS (
        SELECT
            institution.work_id,
            institution.author_id,
            institution.institution_id,
            institution.institution_country_code,
            ROW_NUMBER() OVER (
                PARTITION BY institution.work_id
                ORDER BY institution.author_id, institution.institution_id
            ) AS choice_rank
        FROM read_parquet('{INSTITUTIONS_PATH}') AS institution
        SEMI JOIN family_citer_ids_six AS citer USING (work_id)
        WHERE institution.is_corresponding = TRUE
          AND institution.author_id IS NOT NULL
          AND institution.institution_id IS NOT NULL
    )
    SELECT work_id, author_id, institution_id, institution_country_code
    FROM ranked
    WHERE choice_rank = 1
    """,
)

stage(
    "attention_member_six",
    """
    SELECT
        family.universe,
        family.focal_work_id,
        family.horizon,
        family.citing_work_id,
        metadata.citing_topic_id,
        metadata.citing_field_id,
        metadata.citing_domain_id,
        institution.institution_id AS citing_institution_id,
        institution.institution_country_code AS citing_country_code
    FROM conversation_family_horizon_six AS family
    LEFT JOIN citer_intellectual_metadata_six AS metadata
      ON family.citing_work_id = metadata.work_id
    LEFT JOIN citer_corresponding_institution_six AS institution
      ON family.citing_work_id = institution.work_id
    """,
)

stage(
    "attention_topic_stats_six",
    """
    WITH counts AS (
        SELECT universe, focal_work_id, horizon, citing_topic_id,
               COUNT(*) AS member_count
        FROM attention_member_six
        WHERE citing_topic_id IS NOT NULL
        GROUP BY ALL
    ),
    totals AS (
        SELECT *, SUM(member_count) OVER family AS covered_members
        FROM counts
        WINDOW family AS (
            PARTITION BY universe, focal_work_id, horizon
        )
    )
    SELECT
        universe, focal_work_id, horizon,
        ANY_VALUE(covered_members) AS topic_covered_members,
        COUNT(*) AS distinct_citing_topics,
        1.0 / SUM(POWER(member_count * 1.0 / covered_members, 2))
            AS effective_citing_topics
    FROM totals
    GROUP BY universe, focal_work_id, horizon
    """,
)

stage(
    "attention_field_stats_six",
    """
    WITH counts AS (
        SELECT universe, focal_work_id, horizon, citing_field_id,
               COUNT(*) AS member_count
        FROM attention_member_six
        WHERE citing_field_id IS NOT NULL
        GROUP BY ALL
    ),
    totals AS (
        SELECT *, SUM(member_count) OVER family AS covered_members
        FROM counts
        WINDOW family AS (
            PARTITION BY universe, focal_work_id, horizon
        )
    )
    SELECT
        universe, focal_work_id, horizon,
        ANY_VALUE(covered_members) AS field_covered_members,
        COUNT(*) AS distinct_citing_fields,
        1.0 / SUM(POWER(member_count * 1.0 / covered_members, 2))
            AS effective_citing_fields
    FROM totals
    GROUP BY universe, focal_work_id, horizon
    """,
)

stage(
    "attention_institution_stats_six",
    """
    WITH counts AS (
        SELECT universe, focal_work_id, horizon, citing_institution_id,
               COUNT(*) AS member_count
        FROM attention_member_six
        WHERE citing_institution_id IS NOT NULL
        GROUP BY ALL
    ),
    totals AS (
        SELECT *, SUM(member_count) OVER family AS covered_members
        FROM counts
        WINDOW family AS (
            PARTITION BY universe, focal_work_id, horizon
        )
    )
    SELECT
        universe, focal_work_id, horizon,
        ANY_VALUE(covered_members) AS institution_covered_members,
        COUNT(*) AS distinct_citing_institutions,
        1.0 / SUM(POWER(member_count * 1.0 / covered_members, 2))
            AS effective_citing_institutions
    FROM totals
    GROUP BY universe, focal_work_id, horizon
    """,
)

stage(
    "attention_country_stats_six",
    """
    WITH counts AS (
        SELECT universe, focal_work_id, horizon, citing_country_code,
               COUNT(*) AS member_count
        FROM attention_member_six
        WHERE citing_country_code IS NOT NULL
        GROUP BY ALL
    ),
    totals AS (
        SELECT *, SUM(member_count) OVER family AS covered_members
        FROM counts
        WINDOW family AS (
            PARTITION BY universe, focal_work_id, horizon
        )
    )
    SELECT
        universe, focal_work_id, horizon,
        ANY_VALUE(covered_members) AS country_covered_members,
        COUNT(*) AS distinct_citing_countries,
        1.0 / SUM(POWER(member_count * 1.0 / covered_members, 2))
            AS effective_citing_countries
    FROM totals
    GROUP BY universe, focal_work_id, horizon
    """,
)

stage(
    "attention_breadth_outcomes_six",
    """
    SELECT
        conversation.universe,
        conversation.focal_work_id,
        conversation.analytic_field,
        conversation.focal_year,
        conversation.topic_id,
        conversation.log_authors,
        conversation.oa_value,
        conversation.cell_n,
        conversation.log_eff_j,
        conversation.corresponding_author_id,
        conversation.corresponding_institution_id,
        conversation.field_year_id,
        conversation.horizon,
        conversation.n_citers,
        topic.topic_covered_members,
        topic.distinct_citing_topics,
        topic.effective_citing_topics,
        field.field_covered_members,
        field.distinct_citing_fields,
        field.effective_citing_fields,
        institution.institution_covered_members,
        institution.distinct_citing_institutions,
        institution.effective_citing_institutions,
        country.country_covered_members,
        country.distinct_citing_countries,
        country.effective_citing_countries
    FROM conversation_outcomes_six AS conversation
    LEFT JOIN attention_topic_stats_six AS topic USING (
        universe, focal_work_id, horizon
    )
    LEFT JOIN attention_field_stats_six AS field USING (
        universe, focal_work_id, horizon
    )
    LEFT JOIN attention_institution_stats_six AS institution USING (
        universe, focal_work_id, horizon
    )
    LEFT JOIN attention_country_stats_six AS country USING (
        universe, focal_work_id, horizon
    )
    """,
)

connection.execute(
    """
    COPY (
        SELECT * FROM attention_breadth_outcomes_six
        WHERE horizon = 3 AND n_citers >= 2 AND cell_n >= 20
    ) TO '/private/tmp/attention_breadth_six_3y.parquet'
    (FORMAT PARQUET, COMPRESSION ZSTD)
    """
)

print(connection.execute(
    """
    SELECT universe, analytic_field, COUNT(*) AS focal_papers,
           AVG(effective_citing_topics) AS mean_effective_topics,
           AVG(effective_citing_institutions) AS mean_effective_institutions,
           AVG(effective_citing_countries) AS mean_effective_countries,
           AVG(institution_covered_members * 1.0 / n_citers)
               AS institution_coverage
    FROM attention_breadth_outcomes_six
    WHERE horizon = 3 AND n_citers >= 2 AND cell_n >= 20
    GROUP BY ALL
    ORDER BY universe, analytic_field
    """
).fetchdf().to_string(index=False))

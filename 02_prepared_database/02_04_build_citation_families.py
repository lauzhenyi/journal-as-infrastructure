#!/usr/bin/env python3
"""Build six-field citation-family conversation outcomes."""

from __future__ import annotations

import time

import duckdb


DB_PATH = "/private/tmp/journal_structure_six.duckdb"
WORKS_PATH = "/Volumes/Extreme SSD/openalex_20260203/analytic_work/*.parquet"
EDGES_PATH = (
    "/Volumes/Extreme SSD/openalex_20260203/"
    "analytic_work_reference/*.parquet"
)


connection = duckdb.connect(DB_PATH)
connection.execute("SET threads=8")
connection.execute("SET memory_limit='32GB'")
connection.execute("SET temp_directory='/private/tmp/duckdb_conversation_tmp'")
connection.execute("SET preserve_insertion_order=FALSE")


def exists(table: str) -> bool:
    """Return whether a persistent table already exists."""
    return bool(connection.execute(
        """
        SELECT COUNT(*)
        FROM information_schema.tables
        WHERE table_name = ?
        """,
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
    "eligible_follow_on_works_six",
    f"""
    SELECT
        works.work_id,
        works.publication_year,
        works.publication_date,
        works.source_id,
        CASE WHEN sjr.source_id IS NULL THEN FALSE ELSE TRUE END AS sjr_matched
    FROM read_parquet('{WORKS_PATH}') AS works
    LEFT JOIN sjr_sources AS sjr USING (source_id)
    WHERE works.publication_year BETWEEN 2015 AND 2025
      AND works.work_type = 'article'
      AND works.referenced_works_count > 0
      AND works.source_type = 'journal'
      AND works.source_id IS NOT NULL
    """,
)

stage(
    "conversation_focal_six",
    """
    SELECT
        base.work_id AS focal_work_id,
        base.publication_year AS focal_year,
        base.publication_date AS focal_date,
        base.analytic_field,
        base.topic_id,
        base.source_id AS focal_source_id,
        base.sjr_matched AS focal_sjr_matched,
        base.log_authors,
        base.oa_value,
        author.author_id AS corresponding_author_id,
        institution.institution_id AS corresponding_institution_id
    FROM six_base AS base
    INNER JOIN corresponding_author AS author USING (work_id)
    INNER JOIN corresponding_institution AS institution USING (work_id)
    """,
)

stage(
    "citation_family_six_5y",
    f"""
    SELECT DISTINCT
        focal.focal_work_id,
        focal.focal_year,
        focal.focal_date,
        focal.focal_sjr_matched,
        follow.work_id AS citing_work_id,
        follow.publication_year AS citing_year,
        follow.publication_date AS citing_date,
        follow.source_id AS citing_source_id,
        follow.sjr_matched AS citing_sjr_matched
    FROM read_parquet('{EDGES_PATH}') AS edges
    INNER JOIN conversation_focal_six AS focal
      ON edges.cited_work_id = focal.focal_work_id
     AND edges.citing_year BETWEEN focal.focal_year
                               AND LEAST(2025, focal.focal_year + 4)
    INNER JOIN eligible_follow_on_works_six AS follow
      ON edges.citing_work_id = follow.work_id
     AND edges.citing_year = follow.publication_year
    WHERE edges.citing_work_id <> focal.focal_work_id
    """,
)

stage(
    "family_citer_ids_six",
    """
    SELECT DISTINCT citing_work_id AS work_id
    FROM citation_family_six_5y
    """,
)

stage(
    "candidate_internal_edges_six",
    f"""
    SELECT DISTINCT edges.citing_work_id, edges.cited_work_id
    FROM read_parquet('{EDGES_PATH}') AS edges
    SEMI JOIN family_citer_ids_six AS citing_ids
      ON edges.citing_work_id = citing_ids.work_id
    SEMI JOIN family_citer_ids_six AS cited_ids
      ON edges.cited_work_id = cited_ids.work_id
    WHERE edges.citing_work_id <> edges.cited_work_id
    """,
)

stage(
    "engaged_family_pairs_six",
    """
    SELECT DISTINCT
        later.focal_work_id,
        later.citing_work_id AS later_work_id,
        earlier.citing_work_id AS earlier_work_id,
        later.citing_year AS pair_year,
        later.citing_date AS pair_date,
        later.citing_source_id AS later_source_id,
        earlier.citing_source_id AS earlier_source_id,
        later.citing_sjr_matched AND earlier.citing_sjr_matched
            AS pair_sjr_matched
    FROM citation_family_six_5y AS later
    INNER JOIN candidate_internal_edges_six AS edges
      ON later.citing_work_id = edges.citing_work_id
    INNER JOIN citation_family_six_5y AS earlier
      ON earlier.focal_work_id = later.focal_work_id
     AND earlier.citing_work_id = edges.cited_work_id
    WHERE later.citing_work_id <> earlier.citing_work_id
    """,
)

stage(
    "conversation_family_long_six",
    """
    SELECT
        'full' AS universe,
        focal_work_id,
        focal_year,
        focal_date,
        citing_work_id,
        citing_year,
        citing_date,
        citing_source_id
    FROM citation_family_six_5y
    UNION ALL
    SELECT
        'scimago' AS universe,
        focal_work_id,
        focal_year,
        focal_date,
        citing_work_id,
        citing_year,
        citing_date,
        citing_source_id
    FROM citation_family_six_5y
    WHERE focal_sjr_matched AND citing_sjr_matched
    """,
)

stage(
    "conversation_pair_long_six",
    """
    SELECT 'full' AS universe, *
    FROM engaged_family_pairs_six
    UNION ALL
    SELECT 'scimago' AS universe, *
    FROM engaged_family_pairs_six
    WHERE pair_sjr_matched
    """,
)

stage(
    "conversation_family_horizon_six",
    """
    SELECT family.*, horizon
    FROM conversation_family_long_six AS family,
         (VALUES (2), (3), (5)) AS windows(horizon)
    WHERE family.citing_year <= family.focal_year + horizon - 1
      AND (horizon < 5 OR family.focal_year <= 2021)
    """,
)

stage(
    "conversation_pair_horizon_six",
    """
    SELECT pairs.*, focal.focal_year, horizon
    FROM conversation_pair_long_six AS pairs
    INNER JOIN conversation_focal_six AS focal USING (focal_work_id),
         (VALUES (2), (3), (5)) AS windows(horizon)
    WHERE pairs.pair_year <= focal.focal_year + horizon - 1
      AND (horizon < 5 OR focal.focal_year <= 2021)
    """,
)

stage(
    "conversation_family_stats_six",
    """
    WITH journal_counts AS (
        SELECT universe, focal_work_id, horizon, citing_source_id,
               COUNT(*) AS journal_citers
        FROM conversation_family_horizon_six
        GROUP BY ALL
    ),
    journal_stats AS (
        SELECT
            universe, focal_work_id, horizon,
            SUM(journal_citers) AS n_citers,
            COUNT(*) AS n_citer_journals,
            SUM(journal_citers * (journal_citers - 1) / 2.0)
                AS same_journal_possible_pairs,
            1.0 / SUM(POWER(journal_citers * 1.0 /
                SUM(journal_citers) OVER family, 2)) AS citer_eff_j
        FROM journal_counts
        WINDOW family AS (
            PARTITION BY universe, focal_work_id, horizon
        )
        GROUP BY universe, focal_work_id, horizon
    ),
    first_citation AS (
        SELECT
            universe, focal_work_id, horizon,
            MIN(citing_date) FILTER (
                WHERE citing_date >= focal_date
            ) AS first_citation_date,
            MIN(citing_year) AS first_citation_year,
            AVG(CAST(EXTRACT(MONTH FROM citing_date) = 1 AND
                     EXTRACT(DAY FROM citing_date) = 1 AS DOUBLE))
                AS jan1_date_share
        FROM conversation_family_horizon_six
        GROUP BY ALL
    )
    SELECT journal_stats.*, first_citation.first_citation_date,
           first_citation.first_citation_year,
           first_citation.jan1_date_share
    FROM journal_stats
    INNER JOIN first_citation USING (universe, focal_work_id, horizon)
    """,
)

stage(
    "conversation_pair_stats_six",
    """
    WITH pair_counts AS (
        SELECT
            universe, focal_work_id, horizon,
            COUNT(*) AS internal_ties,
            SUM(CAST(later_source_id <> earlier_source_id AS BIGINT))
                AS cross_journal_ties,
            SUM(CAST(later_source_id = earlier_source_id AS BIGINT))
                AS within_journal_ties,
            MIN(pair_year) AS first_internal_tie_year,
            MIN(pair_date) AS first_internal_tie_date
        FROM conversation_pair_horizon_six
        GROUP BY ALL
    ),
    involved AS (
        SELECT universe, focal_work_id, horizon, COUNT(DISTINCT work_id)
            AS involved_citers
        FROM (
            SELECT universe, focal_work_id, horizon,
                   later_work_id AS work_id
            FROM conversation_pair_horizon_six
            UNION ALL
            SELECT universe, focal_work_id, horizon,
                   earlier_work_id AS work_id
            FROM conversation_pair_horizon_six
        )
        GROUP BY ALL
    )
    SELECT pair_counts.*, involved.involved_citers
    FROM pair_counts
    INNER JOIN involved USING (universe, focal_work_id, horizon)
    """,
)

stage(
    "conversation_outcomes_six",
    """
    SELECT
        articles.universe,
        articles.work_id AS focal_work_id,
        articles.analytic_field,
        articles.publication_year AS focal_year,
        articles.topic_id,
        articles.log_authors,
        articles.oa_value,
        articles.cell_n,
        articles.log_eff_j,
        articles.corresponding_author_id,
        articles.corresponding_institution_id,
        articles.field_year_id,
        windows.horizon,
        COALESCE(family.n_citers, 0) AS n_citers,
        family.n_citer_journals,
        family.citer_eff_j,
        family.same_journal_possible_pairs,
        family.n_citers * (family.n_citers - 1) / 2.0
            AS possible_pairs,
        family.n_citers * (family.n_citers - 1) / 2.0 -
            family.same_journal_possible_pairs
            AS cross_journal_possible_pairs,
        COALESCE(pairs.internal_ties, 0) AS internal_ties,
        COALESCE(pairs.cross_journal_ties, 0) AS cross_journal_ties,
        COALESCE(pairs.within_journal_ties, 0) AS within_journal_ties,
        COALESCE(pairs.involved_citers, 0) AS involved_citers,
        CAST(COALESCE(pairs.internal_ties, 0) > 0 AS DOUBLE)
            AS any_internal_tie,
        CASE WHEN family.n_citers >= 2 THEN
            100.0 * COALESCE(pairs.internal_ties, 0) /
                (family.n_citers * (family.n_citers - 1) / 2.0)
            ELSE NULL END AS internal_tie_density_pp,
        CASE WHEN family.n_citers >= 2 THEN
            1.0 - COALESCE(pairs.involved_citers, 0) * 1.0 /
                family.n_citers
            ELSE NULL END AS isolated_citer_share,
        CASE WHEN family.n_citers * (family.n_citers - 1) / 2.0 -
                       family.same_journal_possible_pairs > 0 THEN
            100.0 * COALESCE(pairs.cross_journal_ties, 0) /
                (family.n_citers * (family.n_citers - 1) / 2.0 -
                 family.same_journal_possible_pairs)
            ELSE NULL END AS cross_journal_tie_density_pp,
        CASE WHEN family.same_journal_possible_pairs > 0 THEN
            100.0 * COALESCE(pairs.within_journal_ties, 0) /
                family.same_journal_possible_pairs
            ELSE NULL END AS within_journal_tie_density_pp,
        pairs.first_internal_tie_year,
        pairs.first_internal_tie_date,
        family.first_citation_year,
        family.first_citation_date,
        family.jan1_date_share
    FROM analysis_articles AS articles
    CROSS JOIN (VALUES (2), (3), (5)) AS windows(horizon)
    LEFT JOIN conversation_family_stats_six AS family
      ON articles.universe = family.universe
     AND articles.work_id = family.focal_work_id
     AND windows.horizon = family.horizon
    LEFT JOIN conversation_pair_stats_six AS pairs
      ON articles.universe = pairs.universe
     AND articles.work_id = pairs.focal_work_id
     AND windows.horizon = pairs.horizon
    WHERE windows.horizon < 5 OR articles.publication_year <= 2021
    """,
)

connection.execute(
    """
    COPY (
        SELECT * FROM conversation_outcomes_six
        WHERE horizon = 3
          AND n_citers >= 2
          AND cell_n >= 20
    ) TO '/private/tmp/conversation_outcomes_six_3y.parquet'
    (FORMAT PARQUET, COMPRESSION ZSTD)
    """
)

print(connection.execute(
    """
    SELECT universe, analytic_field, horizon,
           COUNT(*) AS focal_papers,
           AVG(CAST(n_citers >= 2 AS DOUBLE)) AS share_two_plus_citers,
           AVG(any_internal_tie) FILTER (WHERE n_citers >= 2)
               AS share_any_internal_tie,
           AVG(jan1_date_share) FILTER (WHERE n_citers > 0)
               AS mean_jan1_date_share
    FROM conversation_outcomes_six
    GROUP BY ALL
    ORDER BY universe, horizon, analytic_field
    """
).fetchdf().to_string(index=False))

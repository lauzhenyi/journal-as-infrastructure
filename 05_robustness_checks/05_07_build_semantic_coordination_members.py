#!/usr/bin/env python3
"""Build the semantic-proximity mechanism audit for citation exchange."""

from __future__ import annotations

import os
from pathlib import Path
import time

import duckdb


DATABASE_PATH = os.environ.get(
    "JOURNAL_STRUCTURE_DATABASE",
    "/private/tmp/journal_structure_six.duckdb",
)
OUTPUT_DIRECTORY = Path("results/direct_outcome_gap")
OUTPUT_DIRECTORY.mkdir(parents=True, exist_ok=True)

connection = duckdb.connect(DATABASE_PATH)
connection.execute("SET threads=8")
connection.execute("SET memory_limit='32GB'")
connection.execute(
    "SET temp_directory='/private/tmp/duckdb_semantic_mechanism_tmp'"
)
connection.execute("SET preserve_insertion_order=FALSE")


def build_table(name: str, query: str) -> None:
    """Replace a derived table and report build time and row count."""
    started = time.time()
    connection.execute(f"CREATE OR REPLACE TABLE {name} AS {query}")
    row_count = connection.execute(f"SELECT COUNT(*) FROM {name}").fetchone()[0]
    print(
        f"Built {name}: {row_count:,} rows in {time.time() - started:.1f}s",
        flush=True,
    )


build_table(
    "semantic_coordination_members_six",
    """
    SELECT
        member.universe,
        member.focal_work_id,
        member.citing_work_id,
        member.citing_date,
        member.citing_source_id,
        assignment.text_cluster_id
    FROM temporal_coordination_members_six AS member
    INNER JOIN text_only_cluster_assignments_six AS assignment
      ON member.citing_work_id = assignment.work_id
    """,
)

build_table(
    "semantic_coordination_opportunities_six",
    """
    SELECT
        later.universe,
        later.focal_work_id,
        CAST(
            later.citing_source_id <> earlier.citing_source_id AS INTEGER
        ) AS is_cross_journal,
        CAST(
            later.text_cluster_id = earlier.text_cluster_id AS INTEGER
        ) AS is_same_text_cluster,
        COUNT(*) AS possible_pairs
    FROM semantic_coordination_members_six AS later
    INNER JOIN semantic_coordination_members_six AS earlier
      ON later.universe = earlier.universe
     AND later.focal_work_id = earlier.focal_work_id
     AND later.citing_date > earlier.citing_date
    GROUP BY
        later.universe,
        later.focal_work_id,
        is_cross_journal,
        is_same_text_cluster
    """,
)

build_table(
    "semantic_coordination_realized_six",
    """
    SELECT
        pair.universe,
        pair.focal_work_id,
        CAST(
            later.citing_source_id <> earlier.citing_source_id AS INTEGER
        ) AS is_cross_journal,
        CAST(
            later.text_cluster_id = earlier.text_cluster_id AS INTEGER
        ) AS is_same_text_cluster,
        COUNT(*) AS tie_count
    FROM conversation_pair_horizon_six AS pair
    INNER JOIN semantic_coordination_members_six AS later
      ON pair.universe = later.universe
     AND pair.focal_work_id = later.focal_work_id
     AND pair.later_work_id = later.citing_work_id
    INNER JOIN semantic_coordination_members_six AS earlier
      ON pair.universe = earlier.universe
     AND pair.focal_work_id = earlier.focal_work_id
     AND pair.earlier_work_id = earlier.citing_work_id
    WHERE pair.horizon = 3
      AND later.citing_date > earlier.citing_date
    GROUP BY
        pair.universe,
        pair.focal_work_id,
        is_cross_journal,
        is_same_text_cluster
    """,
)

build_table(
    "semantic_proximity_mechanism_panel_six",
    """
    WITH family_cells AS (
        SELECT
            opportunity.universe,
            focal.publication_year,
            focal.text_cluster_id AS focal_text_cluster_id,
            exposure.log_eff_j,
            opportunity.is_same_text_cluster,
            opportunity.is_cross_journal,
            SUM(opportunity.possible_pairs) AS possible_pairs,
            SUM(COALESCE(realized.tie_count, 0)) AS tie_count
        FROM semantic_coordination_opportunities_six AS opportunity
        INNER JOIN text_only_cluster_assignments_six AS focal
          ON opportunity.focal_work_id = focal.work_id
        INNER JOIN text_only_cluster_exposure_six AS exposure
          ON opportunity.universe = exposure.universe
         AND exposure.scope_name = 'pooled'
         AND focal.publication_year = exposure.publication_year
         AND focal.text_cluster_id = exposure.text_cluster_id
        LEFT JOIN semantic_coordination_realized_six AS realized
          ON opportunity.universe = realized.universe
         AND opportunity.focal_work_id = realized.focal_work_id
         AND opportunity.is_cross_journal = realized.is_cross_journal
         AND opportunity.is_same_text_cluster = realized.is_same_text_cluster
        GROUP BY
            opportunity.universe,
            focal.publication_year,
            focal.text_cluster_id,
            exposure.log_eff_j,
            opportunity.is_same_text_cluster,
            opportunity.is_cross_journal
    ),
    wide AS (
        SELECT
            universe,
            publication_year,
            focal_text_cluster_id,
            ANY_VALUE(log_eff_j) AS log_eff_j,
            is_same_text_cluster,
            SUM(possible_pairs) FILTER (
                WHERE is_cross_journal = 0
            ) AS within_possible_pairs,
            SUM(possible_pairs) FILTER (
                WHERE is_cross_journal = 1
            ) AS cross_possible_pairs,
            SUM(tie_count) FILTER (
                WHERE is_cross_journal = 0
            ) AS within_ties,
            SUM(tie_count) FILTER (
                WHERE is_cross_journal = 1
            ) AS cross_ties
        FROM family_cells
        GROUP BY
            universe,
            publication_year,
            focal_text_cluster_id,
            is_same_text_cluster
    ),
    eligible AS (
        SELECT
            ROW_NUMBER() OVER () AS panel_id,
            *
        FROM wide
        WHERE within_possible_pairs > 0
          AND cross_possible_pairs > 0
    )
    SELECT
        panel_id,
        universe,
        publication_year,
        focal_text_cluster_id,
        log_eff_j,
        is_same_text_cluster,
        0 AS is_cross_journal,
        'within' AS pair_type,
        within_ties AS tie_count,
        within_possible_pairs AS possible_pairs
    FROM eligible
    UNION ALL
    SELECT
        panel_id,
        universe,
        publication_year,
        focal_text_cluster_id,
        log_eff_j,
        is_same_text_cluster,
        1 AS is_cross_journal,
        'cross' AS pair_type,
        cross_ties AS tie_count,
        cross_possible_pairs AS possible_pairs
    FROM eligible
    """,
)

output_path = OUTPUT_DIRECTORY / "semantic_proximity_mechanism_panel.parquet"
connection.execute(
    f"""
    COPY semantic_proximity_mechanism_panel_six
    TO '{output_path}' (FORMAT PARQUET, COMPRESSION ZSTD)
    """
)

violations = connection.execute(
    """
    SELECT COUNT(*)
    FROM semantic_proximity_mechanism_panel_six
    WHERE tie_count > possible_pairs
    """
).fetchone()[0]
if violations:
    raise RuntimeError(f"Found {violations:,} cells with impossible tie counts")

print(
    connection.execute(
        """
        SELECT
            universe,
            is_same_text_cluster,
            pair_type,
            COUNT(*) AS cluster_years,
            SUM(tie_count) AS ties,
            SUM(possible_pairs) AS possible_pairs,
            1000.0 * SUM(tie_count) / SUM(possible_pairs)
                AS ties_per_1000_opportunities
        FROM semantic_proximity_mechanism_panel_six
        GROUP BY universe, is_same_text_cluster, pair_type
        ORDER BY universe, is_same_text_cluster, pair_type
        """
    ).fetchdf().to_string(index=False),
    flush=True,
)

connection.close()

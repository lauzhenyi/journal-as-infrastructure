#!/usr/bin/env python3
"""Export a clean single-paper panel for text-only local exchange models."""

from __future__ import annotations

import os
from pathlib import Path

import duckdb


DATABASE_PATH = os.environ.get(
    "JOURNAL_STRUCTURE_DATABASE",
    "/private/tmp/journal_structure_six.duckdb",
)
OUTPUT_PATH = Path(
    "results/direct_outcome_gap/text_taxonomy_local_exchange.parquet"
)
OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)

connection = duckdb.connect(DATABASE_PATH, read_only=True)
connection.execute("SET threads=8")
connection.execute(
    f"""
    COPY (
        WITH focal_controls AS (
            SELECT
                universe,
                author_id,
                institution_id,
                analytic_field,
                cohort_year,
                COUNT(*) AS focal_papers,
                AVG(log_authors) AS log_authors,
                AVG(oa_value) AS oa_value
            FROM researcher_attention_cohort_six
            GROUP BY
                universe,
                author_id,
                institution_id,
                analytic_field,
                cohort_year
            HAVING COUNT(*) = 1
        )
        SELECT
            coordination.*,
            LOG(exposure.cell_n) AS log_cell_n,
            control.log_authors,
            control.oa_value
        FROM text_only_researcher_coordination_six AS coordination
        INNER JOIN focal_controls AS control USING (
            universe,
            author_id,
            institution_id,
            analytic_field,
            cohort_year
        )
        INNER JOIN text_only_cluster_exposure_six AS exposure
          ON coordination.universe = exposure.universe
         AND coordination.scope_name = exposure.scope_name
         AND coordination.cohort_year = exposure.publication_year
         AND coordination.text_cluster_id = exposure.text_cluster_id
    ) TO '{OUTPUT_PATH}' (FORMAT PARQUET, COMPRESSION ZSTD)
    """
)
connection.close()

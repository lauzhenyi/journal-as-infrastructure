#!/usr/bin/env python3
"""Build compact Full OpenAlex datasets used only by the main figures."""

from __future__ import annotations

import os
from pathlib import Path

import duckdb


DATABASE_PATH = os.environ.get(
    "JOURNAL_STRUCTURE_DATABASE",
    "/private/tmp/journal_structure_six.duckdb",
)
OUTPUT_DIRECTORY = Path("results/direct_outcome_gap/main_figure_data")
OUTPUT_DIRECTORY.mkdir(parents=True, exist_ok=True)

connection = duckdb.connect(DATABASE_PATH, read_only=True)

topic_year_query = """
WITH topic_names AS (
    SELECT topic_id, ANY_VALUE(topic_name) AS topic_name
    FROM six_base
    GROUP BY topic_id
), cells AS (
    SELECT
        analytic_field,
        publication_year,
        topic_id,
        MAX(log_eff_j) AS log_eff_j,
        MAX(focal_families) AS focal_families,
        SUM(tie_count) FILTER (WHERE is_cross_journal = 0) AS within_ties,
        SUM(possible_pairs) FILTER (WHERE is_cross_journal = 0) AS within_possible,
        SUM(tie_count) FILTER (WHERE is_cross_journal = 1) AS cross_ties,
        SUM(possible_pairs) FILTER (WHERE is_cross_journal = 1) AS cross_possible
    FROM temporal_coordination_topic_year_six
    WHERE universe = 'full'
    GROUP BY analytic_field, publication_year, topic_id
)
SELECT
    cells.analytic_field,
    cells.publication_year,
    cells.topic_id,
    topic_names.topic_name,
    EXP(cells.log_eff_j) AS eff_j,
    cells.log_eff_j / LN(2) AS log2_eff_j,
    cells.focal_families,
    cells.within_ties,
    cells.within_possible,
    cells.cross_ties,
    cells.cross_possible,
    1000.0 * cells.within_ties / cells.within_possible AS within_rate_per_1000,
    1000.0 * cells.cross_ties / cells.cross_possible AS cross_rate_per_1000,
    LN((cells.cross_ties + 0.5) / (cells.cross_possible + 1.0))
      - LN((cells.within_ties + 0.5) / (cells.within_possible + 1.0))
      AS log_cross_within_rate_ratio
FROM cells
LEFT JOIN topic_names USING (topic_id)
WHERE cells.within_possible > 0
  AND cells.cross_possible > 0
"""

connection.execute(
    f"COPY ({topic_year_query}) TO '{OUTPUT_DIRECTORY / 'topic_year_descriptives.csv'}' "
    "(HEADER, DELIMITER ',')"
)

topic_examples_query = f"""
WITH cells AS ({topic_year_query}),
topics AS (
    SELECT
        analytic_field,
        topic_id,
        ANY_VALUE(topic_name) AS topic_name,
        MEDIAN(eff_j) AS median_eff_j,
        COUNT(*) AS observed_years,
        SUM(focal_families) AS focal_families
    FROM cells
    GROUP BY analytic_field, topic_id
    HAVING COUNT(*) >= 5
       AND SUM(focal_families) >= 200
), ranked AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY analytic_field
            ORDER BY median_eff_j, focal_families DESC
        ) AS low_rank,
        ROW_NUMBER() OVER (
            PARTITION BY analytic_field
            ORDER BY median_eff_j DESC, focal_families DESC
        ) AS high_rank
    FROM topics
)
SELECT
    analytic_field,
    topic_id,
    topic_name,
    median_eff_j,
    observed_years,
    focal_families,
    CASE WHEN low_rank = 1 THEN 'Low EffJ example' ELSE 'High EffJ example' END
      AS example_type
FROM ranked
WHERE low_rank = 1 OR high_rank = 1
ORDER BY analytic_field, median_eff_j
"""

connection.execute(
    f"COPY ({topic_examples_query}) TO '{OUTPUT_DIRECTORY / 'topic_effj_examples.csv'}' "
    "(HEADER, DELIMITER ',')"
)

topic_medians_query = f"""
WITH cells AS ({topic_year_query})
SELECT
    analytic_field,
    topic_id,
    ANY_VALUE(topic_name) AS topic_name,
    MEDIAN(eff_j) AS median_eff_j,
    COUNT(*) AS observed_years,
    SUM(focal_families) AS focal_families
FROM cells
GROUP BY analytic_field, topic_id
HAVING COUNT(*) >= 5
   AND SUM(focal_families) >= 200
ORDER BY analytic_field, median_eff_j
"""

connection.execute(
    f"COPY ({topic_medians_query}) TO '{OUTPUT_DIRECTORY / 'topic_effj_medians.csv'}' "
    "(HEADER, DELIMITER ',')"
)

print("Wrote topic_year_descriptives.csv")
print("Wrote topic_effj_examples.csv")
print("Wrote topic_effj_medians.csv")

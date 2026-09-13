#!/usr/bin/env python3
"""Build reproducible population, journal-identity, and assignment audit tables."""

from __future__ import annotations

import csv
import math
import os
from pathlib import Path

import duckdb


DATABASE_PATH = os.environ.get(
    "JOURNAL_STRUCTURE_DATABASE",
    "/private/tmp/journal_structure_six.duckdb",
)
OUTPUT_DIRECTORY = Path("results/direct_outcome_gap")
OUTPUT_DIRECTORY.mkdir(parents=True, exist_ok=True)


def write_rows(path: Path, fieldnames: list[str], rows: list[dict[str, object]]) -> None:
    """Write a small audit table with stable column order."""
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


connection = duckdb.connect(DATABASE_PATH, read_only=True)

population_queries = [
    (
        "source_population",
        "Six-field journal articles, 2015-2023, with references and primary metadata",
        "SELECT COUNT(*) FROM six_base",
    ),
    (
        "focal_population",
        "Source population with a selected corresponding author and institution",
        "SELECT COUNT(*) FROM conversation_focal_six",
    ),
    (
        "eligible_follow_on_pool",
        "Eligible follow-on journal articles, 2015-2025",
        "SELECT COUNT(*) FROM eligible_follow_on_works_six",
    ),
    (
        "analytic_families_full",
        "Focal papers with 2-20 date-valid follow-on papers in Full OpenAlex",
        "SELECT COUNT(*) FROM temporal_coordination_opportunities_six WHERE universe='full'",
    ),
    (
        "analytic_families_scimago",
        "Focal papers with 2-20 date-valid follow-on papers in the SCImago subset",
        "SELECT COUNT(*) FROM temporal_coordination_opportunities_six WHERE universe='scimago'",
    ),
    (
        "follow_on_members_full",
        "Follow-on paper memberships in Full OpenAlex analytic families",
        "SELECT COUNT(*) FROM temporal_coordination_members_six WHERE universe='full'",
    ),
    (
        "follow_on_members_scimago",
        "Follow-on paper memberships in SCImago analytic families",
        "SELECT COUNT(*) FROM temporal_coordination_members_six WHERE universe='scimago'",
    ),
]
population_rows: list[dict[str, object]] = []
for stage, definition, query in population_queries:
    value = connection.execute(query).fetchone()[0]
    population_rows.append({"stage": stage, "definition": definition, "count": value})

for universe in ("full", "scimago"):
    within_possible, cross_possible, within_ties, cross_ties = connection.execute(
        """
        SELECT
            SUM(possible_pairs) FILTER (WHERE is_cross_journal=0),
            SUM(possible_pairs) FILTER (WHERE is_cross_journal=1),
            SUM(tie_count) FILTER (WHERE is_cross_journal=0),
            SUM(tie_count) FILTER (WHERE is_cross_journal=1)
        FROM temporal_coordination_topic_year_six
        WHERE universe=?
        """,
        [universe],
    ).fetchone()
    for stage, definition, value in (
        (f"within_possible_pairs_{universe}", "Date-ordered same-journal citation opportunities", within_possible),
        (f"cross_possible_pairs_{universe}", "Date-ordered different-journal citation opportunities", cross_possible),
        (f"within_realized_ties_{universe}", "Realized same-journal citations", within_ties),
        (f"cross_realized_ties_{universe}", "Realized different-journal citations", cross_ties),
    ):
        population_rows.append({"stage": stage, "definition": definition, "count": value})

write_rows(
    OUTPUT_DIRECTORY / "population_summary.csv",
    ["stage", "definition", "count"],
    population_rows,
)

source_count, valid_issnl, duplicated_issnl, sources_duplicated_issnl = connection.execute(
    """
    WITH counts AS (
        SELECT source_issn_l, COUNT(*) AS n
        FROM six_sources
        WHERE source_issn_l IS NOT NULL AND TRIM(source_issn_l) <> ''
        GROUP BY source_issn_l
    )
    SELECT
        (SELECT COUNT(*) FROM six_sources),
        (SELECT COUNT(*) FROM six_sources
            WHERE source_issn_l IS NOT NULL AND TRIM(source_issn_l) <> ''),
        COUNT(*) FILTER (WHERE n > 1),
        COALESCE(SUM(n) FILTER (WHERE n > 1), 0)
    FROM counts
    """
).fetchone()
shared_issn, sources_shared_issn = connection.execute(
    """
    WITH expanded AS (
        SELECT DISTINCT source_id, UPPER(TRIM(issn)) AS issn
        FROM six_sources, UNNEST(source_issn) AS item(issn)
        WHERE issn IS NOT NULL AND TRIM(issn) <> ''
    ), counts AS (
        SELECT issn, COUNT(DISTINCT source_id) AS n
        FROM expanded
        GROUP BY issn
    )
    SELECT
        COUNT(*) FILTER (WHERE n > 1),
        COALESCE(SUM(n) FILTER (WHERE n > 1), 0)
    FROM counts
    """
).fetchone()
annual_rows, ambiguous_rows = connection.execute(
    """
    SELECT COUNT(*), COUNT(*) FILTER (WHERE candidate_count > 1)
    FROM scimago_annual_sjr_source_six
    """
).fetchone()

identity_rows = [
    {"audit": "OpenAlex sources", "value": source_count, "denominator": source_count, "share": 1.0},
    {"audit": "Sources with a valid ISSN-L", "value": valid_issnl, "denominator": source_count, "share": valid_issnl / source_count},
    {"audit": "Duplicated ISSN-L values across source_id", "value": duplicated_issnl, "denominator": valid_issnl, "share": duplicated_issnl / valid_issnl},
    {"audit": "Sources involved in duplicated ISSN-L", "value": sources_duplicated_issnl, "denominator": source_count, "share": sources_duplicated_issnl / source_count},
    {"audit": "ISSNs shared across source_id", "value": shared_issn, "denominator": source_count, "share": shared_issn / source_count},
    {"audit": "Sources involved in shared ISSNs", "value": sources_shared_issn, "denominator": source_count, "share": sources_shared_issn / source_count},
    {"audit": "Ambiguous annual SJR matches", "value": ambiguous_rows, "denominator": annual_rows, "share": ambiguous_rows / annual_rows},
]
write_rows(
    OUTPUT_DIRECTORY / "journal_identity_audit.csv",
    ["audit", "value", "denominator", "share"],
    identity_rows,
)


def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open(encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


assignment_rows: list[dict[str, object]] = []
self_rows = read_csv(OUTPUT_DIRECTORY / "self_citation_sensitivity_results.csv")
for row in self_rows:
    if row["analytic_field"] != "pooled" or row["sensitivity"] != "all_ties":
        continue
    assignment_rows.append(
        {
            "model_level": row["model_level"],
            "universe": row["universe"],
            "assignment": "OpenAlex primary topic and primary field",
            "effect_percent": row["percent_change_for_effj_doubling"],
            "ci_low_percent": row["ci_low_percent"],
            "ci_high_percent": row["ci_high_percent"],
            "p_value": row["p_value"],
            "observations": row["observations"],
        }
    )

for filename, model_level, scope_column in (
    ("text_only_coordination_fe_results.csv", "topic_year", "scope_name"),
    ("text_only_researcher_fe_results.csv", "corresponding_author", "analytic_field"),
):
    for row in read_csv(OUTPUT_DIRECTORY / filename):
        if row[scope_column] != "pooled":
            continue
        effect = float(row["percent_change_for_effj_doubling"])
        log_effect = math.log1p(effect / 100.0)
        standard_error = float(row["standard_error_log_rate_doubling"])
        assignment_rows.append(
            {
                "model_level": model_level,
                "universe": row["universe"],
                "assignment": "Title-abstract-only 256-cluster taxonomy",
                "effect_percent": effect,
                "ci_low_percent": 100.0 * (math.exp(log_effect - 1.96 * standard_error) - 1.0),
                "ci_high_percent": 100.0 * (math.exp(log_effect + 1.96 * standard_error) - 1.0),
                "p_value": row["p_value"],
                "observations": row["observations"],
            }
        )

write_rows(
    OUTPUT_DIRECTORY / "assignment_sensitivity_results.csv",
    [
        "model_level",
        "universe",
        "assignment",
        "effect_percent",
        "ci_low_percent",
        "ci_high_percent",
        "p_value",
        "observations",
    ],
    assignment_rows,
)

print("Wrote population_summary.csv")
print("Wrote journal_identity_audit.csv")
print("Wrote assignment_sensitivity_results.csv")

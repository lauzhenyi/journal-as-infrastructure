#!/usr/bin/env python3
"""Validate the prepared DuckDB used by the journal-structure analyses.

This script is read-only. It verifies the upstream tables created by the
numbered preparation files, prints row counts, and reports language coverage
in the two article tables.
"""

from __future__ import annotations

import os
from pathlib import Path

import duckdb


DATABASE_PATH = Path(
    os.environ.get(
        "JOURNAL_STRUCTURE_DATABASE",
        "/private/tmp/journal_structure_six.duckdb",
    )
)

REQUIRED_TABLES = (
    "six_base",
    "paper_universes",
    "analysis_articles",
    "corresponding_author",
    "corresponding_institution",
    "eligible_follow_on_works_six",
    "journal_topic_year_counts_six",
    "journal_exposure",
    "attention_member_six",
    "family_citer_ids_six",
    "citer_intellectual_metadata_six",
    "conversation_focal_six",
    "conversation_family_long_six",
    "conversation_pair_long_six",
    "conversation_family_horizon_six",
    "conversation_pair_horizon_six",
    "conversation_outcomes_six",
    "citer_corresponding_institution_six",
    "researcher_attention_cohort_six",
    "researcher_attention_panel_six",
    "journal_exposure_alternatives_six",
    "robust_topic_exposure_six",
    "scimago_annual_sjr_source_six",
)


def main() -> None:
    """Run the cache checks and print a compact audit."""
    if not DATABASE_PATH.exists():
        raise FileNotFoundError(f"Prepared database not found: {DATABASE_PATH}")

    connection = duckdb.connect(str(DATABASE_PATH), read_only=True)
    available = {
        row[0]
        for row in connection.execute(
            "SELECT table_name FROM duckdb_tables()"
        ).fetchall()
    }
    missing = [table for table in REQUIRED_TABLES if table not in available]
    if missing:
        raise RuntimeError(f"Missing required tables: {', '.join(missing)}")

    print(f"Database: {DATABASE_PATH}")
    print(f"Required tables present: {len(REQUIRED_TABLES)}")
    print("\nRow counts")
    for table in REQUIRED_TABLES:
        row_count = connection.execute(
            f'SELECT COUNT(*) FROM "{table}"'
        ).fetchone()[0]
        print(f"{table}\t{row_count}")

    print("\nLanguage coverage")
    for table in ("six_base", "analysis_articles"):
        total, english, language_count = connection.execute(
            f"""
            SELECT
                COUNT(*) AS total_rows,
                SUM(CASE WHEN language = 'en' THEN 1 ELSE 0 END)
                    AS english_rows,
                COUNT(DISTINCT language) AS language_count
            FROM "{table}"
            """
        ).fetchone()
        print(
            f"{table}\ttotal={total}\tenglish={english}"
            f"\tlanguages={language_count}"
        )

if __name__ == "__main__":
    main()

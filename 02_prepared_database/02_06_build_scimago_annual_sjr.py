#!/usr/bin/env python3
"""Build direct early-citation outcomes with annual SCImago prestige."""

from __future__ import annotations

import csv
from pathlib import Path
import time

import duckdb


DB_PATH = "/private/tmp/journal_structure_six.duckdb"
SCIMAGO_DIR = Path(
    "/Volumes/Extreme SSD/RA/computational_sociology/scimagojr"
)
SOURCE_PATH = (
    "/Volumes/Extreme SSD/openalex_20260203/"
    "analytic_source_dim/*.parquet"
)
ANNUAL_CSV = Path("/private/tmp/scimago_annual_sjr_2015_2024.csv")


def normalize_issn(value: str) -> str:
    """Return an eight-character ISSN without punctuation."""
    return "".join(character for character in value.upper() if character.isalnum())


def parse_decimal_comma(value: str) -> float | None:
    """Parse SCImago decimal-comma values."""
    cleaned = value.strip().replace(".", "").replace(",", ".")
    if not cleaned or cleaned == "-":
        return None
    return float(cleaned)


def write_annual_sjr() -> None:
    """Normalize annual SCImago files to one row per ISSN and year."""
    with ANNUAL_CSV.open("w", newline="", encoding="utf-8") as output_stream:
        writer = csv.DictWriter(
            output_stream,
            fieldnames=[
                "year",
                "scimago_source_id",
                "title",
                "issn",
                "sjr",
                "best_quartile",
            ],
        )
        writer.writeheader()
        for year in range(2015, 2025):
            input_path = SCIMAGO_DIR / f"scimagojr {year}.csv"
            with input_path.open("r", newline="", encoding="utf-8-sig") as input_stream:
                reader = csv.DictReader(input_stream, delimiter=";")
                for row in reader:
                    sjr = parse_decimal_comma(row.get("SJR", ""))
                    if sjr is None or sjr <= 0:
                        continue
                    issns = {
                        normalize_issn(value)
                        for value in row.get("Issn", "").split(",")
                    }
                    for issn in sorted(value for value in issns if len(value) == 8):
                        writer.writerow(
                            {
                                "year": year,
                                "scimago_source_id": row.get("Sourceid", ""),
                                "title": row.get("Title", ""),
                                "issn": issn,
                                "sjr": sjr,
                                "best_quartile": row.get("SJR Best Quartile", ""),
                            }
                        )


write_annual_sjr()

connection = duckdb.connect(DB_PATH)
connection.execute("SET threads=8")
connection.execute("SET memory_limit='32GB'")
connection.execute("SET temp_directory='/private/tmp/duckdb_prestige_timing_tmp'")
connection.execute("SET preserve_insertion_order=FALSE")

started = time.time()
connection.execute(
    f"""
    CREATE OR REPLACE TABLE scimago_annual_sjr_source_six AS
    WITH annual AS (
        SELECT year, scimago_source_id, title, issn, sjr, best_quartile
        FROM read_csv_auto('{ANNUAL_CSV}', header = TRUE)
    ),
    source_issns AS (
        SELECT source.id AS source_id,
               REPLACE(unnested.issn, '-', '') AS issn,
               CAST(unnested.issn = source.issn_l AS INTEGER) AS is_issn_l
        FROM read_parquet('{SOURCE_PATH}') AS source,
             UNNEST(source.issn) AS unnested(issn)
        WHERE source.type = 'journal'
    ),
    candidates AS (
        SELECT source.source_id, annual.*,
               source.is_issn_l,
               COUNT(DISTINCT annual.scimago_source_id) OVER (
                   PARTITION BY source.source_id, annual.year
               ) AS candidate_count,
               ROW_NUMBER() OVER (
                   PARTITION BY source.source_id, annual.year
                   ORDER BY source.is_issn_l DESC, annual.sjr DESC,
                            annual.scimago_source_id
               ) AS candidate_rank
        FROM source_issns AS source
        INNER JOIN annual USING (issn)
    )
    SELECT source_id, year, scimago_source_id, title, sjr,
           LN(sjr) AS log_sjr, best_quartile, candidate_count
    FROM candidates
    WHERE candidate_rank = 1
    """
)

connection.execute(
    """
    CREATE OR REPLACE TABLE first_citation_date_six AS
    WITH dates AS (
        SELECT member.universe, member.focal_work_id,
               MIN(citer.publication_date) AS first_date_any,
               MIN(citer.publication_date) FILTER (
                   WHERE EXTRACT(month FROM citer.publication_date) <> 1
                      OR EXTRACT(day FROM citer.publication_date) <> 1
               ) AS first_date_nonplaceholder
        FROM attention_member_six AS member
        INNER JOIN eligible_follow_on_works_six AS citer
          ON member.citing_work_id = citer.work_id
        WHERE member.horizon = 3
        GROUP BY ALL
    )
    SELECT * FROM dates
    """
)

connection.execute(
    """
    CREATE OR REPLACE TABLE real_outcome_prestige_timing_six AS
    WITH matched AS (
        SELECT article.*,
               same_year.sjr AS sjr_same_year,
               same_year.log_sjr AS log_sjr_same_year,
               same_year.best_quartile AS quartile_same_year,
               same_year.candidate_count AS same_year_candidate_count,
               lagged.sjr AS sjr_lagged,
               lagged.log_sjr AS log_sjr_lagged,
               lagged.best_quartile AS quartile_lagged,
               lagged.candidate_count AS lagged_candidate_count,
               citation.first_date_any,
               citation.first_date_nonplaceholder,
               DATE_DIFF('day', article.publication_date,
                         citation.first_date_nonplaceholder) AS first_citation_days,
               CAST(
                   EXTRACT(month FROM article.publication_date) = 1
                   AND EXTRACT(day FROM article.publication_date) = 1
                   AS INTEGER
               ) AS focal_date_placeholder,
               CAST(
                   citation.first_date_any IS NOT NULL
                   AND EXTRACT(month FROM citation.first_date_any) = 1
                   AND EXTRACT(day FROM citation.first_date_any) = 1
                   AS INTEGER
               ) AS first_citation_placeholder
        FROM analysis_articles AS article
        INNER JOIN scimago_annual_sjr_source_six AS same_year
          ON article.source_id = same_year.source_id
         AND article.publication_year = same_year.year
        LEFT JOIN scimago_annual_sjr_source_six AS lagged
          ON article.source_id = lagged.source_id
         AND article.publication_year - 1 = lagged.year
        LEFT JOIN first_citation_date_six AS citation
          ON article.universe = citation.universe
         AND article.work_id = citation.focal_work_id
        WHERE article.corresponding_author_id IS NOT NULL
          AND article.corresponding_institution_id IS NOT NULL
          AND article.cell_n >= 20
    ),
    clean AS (
        SELECT *,
               CAST(COALESCE(
                   first_citation_days BETWEEN 0 AND 180, FALSE
               ) AS INTEGER)
                   AS cited_within_180d,
               CAST(COALESCE(
                   first_citation_days BETWEEN 0 AND 365, FALSE
               ) AS INTEGER)
                   AS cited_within_365d,
               CAST(COALESCE(
                   first_citation_days BETWEEN 0 AND 730, FALSE
               ) AS INTEGER)
                   AS cited_within_730d,
               LEAST(COALESCE(first_citation_days, 365), 365)
                   AS first_citation_days_capped_365,
               LN(cell_n) AS log_cell_n
        FROM matched
        WHERE focal_date_placeholder = 0
          AND first_citation_placeholder = 0
          AND (
              first_citation_days IS NULL
              OR first_citation_days >= 0
          )
    )
    SELECT *,
           (log_sjr_same_year - AVG(log_sjr_same_year) OVER field_year) /
               NULLIF(STDDEV_SAMP(log_sjr_same_year) OVER field_year, 0)
               AS z_log_sjr_same_year,
           (log_sjr_lagged - AVG(log_sjr_lagged) OVER field_year) /
               NULLIF(STDDEV_SAMP(log_sjr_lagged) OVER field_year, 0)
               AS z_log_sjr_lagged
    FROM clean
    WINDOW field_year AS (
        PARTITION BY universe, analytic_field, publication_year
    )
    """
)

row_count = connection.execute(
    "SELECT COUNT(*) FROM real_outcome_prestige_timing_six"
).fetchone()[0]
print(
    f"Built real_outcome_prestige_timing_six: {row_count:,} rows "
    f"in {time.time() - started:.1f}s",
    flush=True,
)

connection.execute(
    """
    COPY real_outcome_prestige_timing_six
    TO '/private/tmp/real_outcome_prestige_timing_six.parquet'
    (FORMAT PARQUET, COMPRESSION ZSTD)
    """
)

print(connection.execute(
    """
    SELECT universe, analytic_field, COUNT(*) AS papers,
           AVG(cited_within_365d) AS cited_365_rate,
           AVG(CAST(sjr_lagged IS NOT NULL AS INTEGER)) AS lagged_sjr_coverage,
           AVG(CAST(same_year_candidate_count > 1 AS INTEGER))
               AS ambiguous_source_match_share
    FROM real_outcome_prestige_timing_six
    GROUP BY ALL
    ORDER BY universe, analytic_field
    """
).fetchdf().to_string(index=False))

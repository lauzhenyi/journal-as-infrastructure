#!/usr/bin/env python3
"""Build reproducible sample-size and descriptive-statistics tables."""

from __future__ import annotations

import csv
import os
from pathlib import Path

import duckdb


DATABASE_PATH = os.environ.get(
    "JOURNAL_STRUCTURE_DATABASE",
    "/private/tmp/journal_structure_six.duckdb",
)
OUTPUT_DIRECTORY = Path("results/direct_outcome_gap")
OUTPUT_DIRECTORY.mkdir(parents=True, exist_ok=True)


def write_query(
    connection: duckdb.DuckDBPyConnection,
    query: str,
    output_path: Path,
) -> None:
    """Run a query and write its result with a stable CSV header."""
    result = connection.execute(query)
    columns = [item[0] for item in result.description]
    with output_path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow(columns)
        writer.writerows(result.fetchall())


connection = duckdb.connect(DATABASE_PATH, read_only=True)

field_order = """
CASE analytic_field
    WHEN 'biology' THEN 1
    WHEN 'chemistry' THEN 2
    WHEN 'geology' THEN 3
    WHEN 'materials_science' THEN 4
    WHEN 'medicine' THEN 5
    WHEN 'physics' THEN 6
    WHEN 'total' THEN 7
END
"""

sample_flow_query = f"""
WITH source AS (
    SELECT
        analytic_field,
        COUNT(*) AS source_papers,
        COUNT(DISTINCT source_id) AS journals
    FROM six_base
    GROUP BY analytic_field
), focal AS (
    SELECT
        analytic_field,
        COUNT(*) AS papers_with_author_institution_assignment
    FROM conversation_focal_six
    GROUP BY analytic_field
), families AS (
    SELECT f.analytic_field, COUNT(*) AS analytic_families
    FROM temporal_coordination_opportunities_six AS o
    JOIN conversation_focal_six AS f
      ON f.focal_work_id = o.focal_work_id
    WHERE o.universe = 'full'
    GROUP BY f.analytic_field
), members AS (
    SELECT f.analytic_field, COUNT(*) AS follow_on_memberships
    FROM temporal_coordination_members_six AS m
    JOIN conversation_focal_six AS f
      ON f.focal_work_id = m.focal_work_id
    WHERE m.universe = 'full'
    GROUP BY f.analytic_field
), opportunities AS (
    SELECT
        analytic_field,
        SUM(possible_pairs) AS citation_opportunities,
        SUM(tie_count) AS realized_citations
    FROM temporal_coordination_topic_year_six
    WHERE universe = 'full'
    GROUP BY analytic_field
), field_rows AS (
    SELECT
        s.analytic_field,
        s.source_papers,
        s.journals,
        f.papers_with_author_institution_assignment,
        a.analytic_families,
        m.follow_on_memberships,
        o.citation_opportunities,
        o.realized_citations
    FROM source AS s
    JOIN focal AS f USING (analytic_field)
    JOIN families AS a USING (analytic_field)
    JOIN members AS m USING (analytic_field)
    JOIN opportunities AS o USING (analytic_field)
), total_row AS (
    SELECT
        'total' AS analytic_field,
        (SELECT COUNT(*) FROM six_base) AS source_papers,
        (SELECT COUNT(DISTINCT source_id) FROM six_base) AS journals,
        (SELECT COUNT(*) FROM conversation_focal_six)
          AS papers_with_author_institution_assignment,
        (SELECT COUNT(*) FROM temporal_coordination_opportunities_six
          WHERE universe = 'full') AS analytic_families,
        (SELECT COUNT(*) FROM temporal_coordination_members_six
          WHERE universe = 'full') AS follow_on_memberships,
        (SELECT SUM(possible_pairs) FROM temporal_coordination_topic_year_six
          WHERE universe = 'full') AS citation_opportunities,
        (SELECT SUM(tie_count) FROM temporal_coordination_topic_year_six
          WHERE universe = 'full') AS realized_citations
)
SELECT * FROM (
    SELECT * FROM field_rows
    UNION ALL
    SELECT * FROM total_row
) AS combined
ORDER BY {field_order}
"""

analytic_descriptives_query = f"""
WITH family_sizes AS (
    SELECT
        f.analytic_field,
        m.focal_work_id,
        ANY_VALUE(m.clean_family_size) AS family_size
    FROM temporal_coordination_members_six AS m
    JOIN conversation_focal_six AS f
      ON f.focal_work_id = m.focal_work_id
    WHERE m.universe = 'full'
    GROUP BY f.analytic_field, m.focal_work_id
), family_summary AS (
    SELECT
        analytic_field,
        AVG(family_size) AS mean_family_size,
        MEDIAN(family_size) AS median_family_size,
        QUANTILE_CONT(family_size, 0.25) AS p25_family_size,
        QUANTILE_CONT(family_size, 0.75) AS p75_family_size
    FROM family_sizes
    GROUP BY analytic_field
), exposure_values AS (
    SELECT f.analytic_field, e.eff_j
    FROM temporal_coordination_opportunities_six AS o
    JOIN conversation_focal_six AS f
      ON f.focal_work_id = o.focal_work_id
    JOIN journal_exposure AS e
      ON e.universe = o.universe
     AND e.analytic_field = f.analytic_field
     AND e.publication_year = f.focal_year
     AND e.topic_id = f.topic_id
    WHERE o.universe = 'full'
), exposure_summary AS (
    SELECT
        analytic_field,
        AVG(eff_j) AS mean_effj,
        MEDIAN(eff_j) AS median_effj,
        QUANTILE_CONT(eff_j, 0.25) AS p25_effj,
        QUANTILE_CONT(eff_j, 0.75) AS p75_effj
    FROM exposure_values
    GROUP BY analytic_field
), tie_summary AS (
    SELECT
        analytic_field,
        COUNT(DISTINCT topic_id || '|' || CAST(publication_year AS VARCHAR))
          AS topic_year_cells,
        SUM(possible_pairs) FILTER (WHERE is_cross_journal = 0)
          AS within_opportunities,
        SUM(possible_pairs) FILTER (WHERE is_cross_journal = 1)
          AS across_opportunities,
        SUM(tie_count) FILTER (WHERE is_cross_journal = 0) AS within_citations,
        SUM(tie_count) FILTER (WHERE is_cross_journal = 1) AS across_citations
    FROM temporal_coordination_topic_year_six
    WHERE universe = 'full'
    GROUP BY analytic_field
), field_rows AS (
    SELECT
        f.analytic_field,
        t.topic_year_cells,
        f.mean_family_size,
        f.median_family_size,
        f.p25_family_size,
        f.p75_family_size,
        e.mean_effj,
        e.median_effj,
        e.p25_effj,
        e.p75_effj,
        t.within_opportunities,
        t.across_opportunities,
        t.within_citations,
        t.across_citations,
        100.0 * t.within_citations / t.within_opportunities
          AS within_citation_rate_pct,
        100.0 * t.across_citations / t.across_opportunities
          AS across_citation_rate_pct,
        (CAST(t.across_citations AS DOUBLE) / t.across_opportunities) /
          (CAST(t.within_citations AS DOUBLE) / t.within_opportunities)
          AS raw_cjr
    FROM family_summary AS f
    JOIN exposure_summary AS e USING (analytic_field)
    JOIN tie_summary AS t USING (analytic_field)
), total_row AS (
    SELECT
        'total' AS analytic_field,
        (SELECT COUNT(DISTINCT topic_id || '|' || CAST(publication_year AS VARCHAR))
         FROM temporal_coordination_topic_year_six WHERE universe = 'full')
          AS topic_year_cells,
        (SELECT AVG(family_size) FROM family_sizes) AS mean_family_size,
        (SELECT MEDIAN(family_size) FROM family_sizes) AS median_family_size,
        (SELECT QUANTILE_CONT(family_size, 0.25) FROM family_sizes)
          AS p25_family_size,
        (SELECT QUANTILE_CONT(family_size, 0.75) FROM family_sizes)
          AS p75_family_size,
        (SELECT AVG(eff_j) FROM exposure_values) AS mean_effj,
        (SELECT MEDIAN(eff_j) FROM exposure_values) AS median_effj,
        (SELECT QUANTILE_CONT(eff_j, 0.25) FROM exposure_values) AS p25_effj,
        (SELECT QUANTILE_CONT(eff_j, 0.75) FROM exposure_values) AS p75_effj,
        SUM(within_opportunities) AS within_opportunities,
        SUM(across_opportunities) AS across_opportunities,
        SUM(within_citations) AS within_citations,
        SUM(across_citations) AS across_citations,
        100.0 * SUM(within_citations) / SUM(within_opportunities)
          AS within_citation_rate_pct,
        100.0 * SUM(across_citations) / SUM(across_opportunities)
          AS across_citation_rate_pct,
        (CAST(SUM(across_citations) AS DOUBLE) / SUM(across_opportunities)) /
          (CAST(SUM(within_citations) AS DOUBLE) / SUM(within_opportunities))
          AS raw_cjr
    FROM tie_summary
)
SELECT * FROM (
    SELECT * FROM field_rows
    UNION ALL
    SELECT * FROM total_row
) AS combined
ORDER BY {field_order}
"""

later_uptake_query = f"""
SELECT
    COALESCE(analytic_field, 'total') AS analytic_field,
    COUNT(*) AS raw_family_rows,
    SUM(early_member_count) AS early_member_memberships,
    SUM(late_member_count) AS late_member_memberships,
    SUM(eligible_late_citers) AS eligible_later_papers,
    SUM(late_citers_with_handoff) AS later_papers_citing_early_work,
    100.0 * SUM(late_citers_with_handoff) / SUM(eligible_late_citers)
      AS later_uptake_pct,
    SUM(possible_handoffs) AS possible_later_to_early_citations,
    SUM(realized_handoffs) AS realized_later_to_early_citations,
    100.0 * SUM(realized_handoffs) / SUM(possible_handoffs)
      AS later_to_early_citation_rate_pct
FROM cumulative_handoff_family_panel_six
WHERE universe = 'full'
GROUP BY GROUPING SETS ((analytic_field), ())
ORDER BY {field_order}
"""

later_uptake_cohort_query = """
SELECT
    publication_year AS focal_year,
    COUNT(*) AS lineages,
    SUM(eligible_late_citers) AS eligible_later_papers,
    SUM(late_citers_with_handoff) AS later_papers_citing_early_work,
    100.0 * SUM(late_citers_with_handoff) / SUM(eligible_late_citers)
      AS later_uptake_pct,
    CASE
        WHEN publication_year <= 2020 THEN 'Complete'
        WHEN publication_year = 2021 THEN 'Incomplete fifth year'
        ELSE 'Outside years 4-5 analysis window'
    END AS observation_status
FROM cumulative_handoff_family_panel_six
WHERE universe = 'full'
GROUP BY publication_year
ORDER BY publication_year
"""

model_sample_query = f"""
WITH cjr AS (
    SELECT
        analytic_field,
        MAX(observations) FILTER (WHERE model_level = 'corresponding_author')
          AS author_institution_cjr_rows,
        MAX(observations) FILTER (WHERE model_level = 'topic_year')
          AS subfield_year_cjr_rows
    FROM read_csv_auto(
      'results/direct_outcome_gap/self_citation_sensitivity_results.csv'
    )
    WHERE universe = 'full' AND sensitivity = 'all_ties'
    GROUP BY analytic_field
), later AS (
    SELECT
        analytic_field,
        MAX(observations) AS later_uptake_family_rows
    FROM read_csv_auto(
      'results/cumulative_handoff/later_uptake_cross_share_results.csv'
    )
    WHERE universe = 'full'
      AND cohort = '2015-2021'
      AND specification =
        'Total early ties and cross-versus-within opportunities'
    GROUP BY analytic_field
), later_boundary AS (
    SELECT
        analytic_field,
        MAX(observations) AS later_cross_journal_rows
    FROM read_csv_auto(
      'results/cumulative_handoff/cumulative_handoff_results.csv'
    )
    WHERE universe = 'full'
      AND scale = 'subfield_cross_boundary_handoff'
      AND (analytic_field = 'pooled' OR analytic_field NOT LIKE 'exclude_%')
    GROUP BY analytic_field
), joint_path AS (
    SELECT
        analytic_field,
        mediator_observations AS joint_mediator_rows,
        outcome_observations_joint AS joint_outcome_rows,
        topics AS joint_topics
    FROM read_csv_auto(
      'results/cumulative_handoff/joint_effj_cjr_handoff_results.csv'
    )
    WHERE universe = 'full'
), combined AS (
    SELECT
        CASE WHEN c.analytic_field = 'pooled' THEN 'total'
             ELSE c.analytic_field END AS analytic_field,
        c.author_institution_cjr_rows,
        c.subfield_year_cjr_rows,
        l.later_uptake_family_rows,
        b.later_cross_journal_rows,
        j.joint_mediator_rows,
        j.joint_outcome_rows,
        j.joint_topics
    FROM cjr AS c
    JOIN later AS l USING (analytic_field)
    JOIN later_boundary AS b USING (analytic_field)
    JOIN joint_path AS j USING (analytic_field)
)
SELECT * FROM combined
ORDER BY {field_order}
"""

write_query(
    connection,
    sample_flow_query,
    OUTPUT_DIRECTORY / "sample_flow_by_field.csv",
)
write_query(
    connection,
    analytic_descriptives_query,
    OUTPUT_DIRECTORY / "analytic_descriptives_by_field.csv",
)
write_query(
    connection,
    later_uptake_query,
    OUTPUT_DIRECTORY / "later_uptake_descriptives_by_field.csv",
)
write_query(
    connection,
    later_uptake_cohort_query,
    OUTPUT_DIRECTORY / "later_uptake_cohort_by_year.csv",
)
write_query(
    connection,
    model_sample_query,
    OUTPUT_DIRECTORY / "model_sample_sizes_by_field.csv",
)

print("Wrote sample_flow_by_field.csv")
print("Wrote analytic_descriptives_by_field.csv")
print("Wrote later_uptake_descriptives_by_field.csv")
print("Wrote later_uptake_cohort_by_year.csv")
print("Wrote model_sample_sizes_by_field.csv")

#!/usr/bin/env python3
"""Build a text-only taxonomy audit for the coordination result."""

from __future__ import annotations

import json
import os
from pathlib import Path
import time

import duckdb
import joblib
import numpy as np
import pyarrow as pa
import pyarrow.parquet as pq
from sklearn.cluster import MiniBatchKMeans
from sklearn.feature_extraction.text import HashingVectorizer


DATABASE_PATH = os.environ.get(
    "JOURNAL_STRUCTURE_DATABASE",
    "/private/tmp/journal_structure_six.duckdb",
)
TEXT_PATH = (
    "/Volumes/Extreme SSD/openalex_20260203/analytic_work_text/*.parquet"
)
OUTPUT_DIRECTORY = Path("results/direct_outcome_gap")
ASSIGNMENT_PATH = OUTPUT_DIRECTORY / "text_only_cluster_assignments.parquet"
MODEL_PATH = OUTPUT_DIRECTORY / "text_only_cluster_model.joblib"
METADATA_PATH = OUTPUT_DIRECTORY / "text_only_cluster_metadata.json"

RANDOM_SEED = 20260826
N_FEATURES = 32768
N_CLUSTERS = 256
FIT_PER_FIELD = 20000
ASSIGNMENT_MODULUS = 4
MIN_CLUSTER_YEAR_ARTICLES = 200

FIELDS = (
    "biology",
    "chemistry",
    "geology",
    "materials_science",
    "medicine",
    "physics",
)

OUTPUT_DIRECTORY.mkdir(parents=True, exist_ok=True)

connection = duckdb.connect(DATABASE_PATH)
connection.execute("SET threads=8")
connection.execute("SET memory_limit='32GB'")
connection.execute(
    "SET temp_directory='/private/tmp/duckdb_text_taxonomy_tmp'"
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


base_query = f"""
    SELECT
        article.work_id,
        article.publication_year,
        article.analytic_field,
        COALESCE(text.title, '') || ' ' ||
            LEFT(COALESCE(text.abstract, ''), 1500) AS document_text
    FROM analysis_articles AS article
    INNER JOIN read_parquet('{TEXT_PATH}') AS text USING (work_id)
    WHERE article.universe = 'full'
      AND article.analytic_field IN ({", ".join(repr(field) for field in FIELDS)})
      AND LENGTH(TRIM(COALESCE(text.title, ''))) > 0
      AND LENGTH(TRIM(COALESCE(text.abstract, ''))) > 0
"""

fit_query = f"""
    WITH candidates AS (
        {base_query}
    )
    SELECT work_id, publication_year, analytic_field, document_text
    FROM candidates
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY analytic_field
        ORDER BY HASH(work_id || ':fit:{RANDOM_SEED}')
    ) <= {FIT_PER_FIELD}
"""

print("Loading deterministic text-only training sample", flush=True)
fit_frame = connection.execute(fit_query).fetchdf()

vectorizer = HashingVectorizer(
    n_features=N_FEATURES,
    alternate_sign=False,
    norm="l2",
    stop_words="english",
    ngram_range=(1, 2),
    dtype=np.float32,
)
fit_matrix = vectorizer.transform(fit_frame["document_text"].tolist())
model = MiniBatchKMeans(
    n_clusters=N_CLUSTERS,
    random_state=RANDOM_SEED,
    batch_size=4096,
    n_init=3,
    max_iter=100,
    reassignment_ratio=0.01,
)
started = time.time()
model.fit(fit_matrix)
print(
    f"Fit {N_CLUSTERS} text-only clusters on {len(fit_frame):,} works "
    f"in {time.time() - started:.1f}s",
    flush=True,
)
joblib.dump(model, MODEL_PATH, compress=3)

assignment_query = f"""
    WITH candidates AS (
        {base_query}
    )
    SELECT work_id, publication_year, analytic_field, document_text
    FROM candidates
    WHERE HASH(work_id || ':assign:{RANDOM_SEED}') % {ASSIGNMENT_MODULUS} = 0
    ORDER BY publication_year, work_id
"""

schema = pa.schema(
    [
        pa.field("work_id", pa.string()),
        pa.field("publication_year", pa.int16()),
        pa.field("analytic_field", pa.string()),
        pa.field("text_cluster_id", pa.int16()),
    ]
)
writer = pq.ParquetWriter(ASSIGNMENT_PATH, schema, compression="zstd")
assigned_rows = 0
cluster_counts = [0] * N_CLUSTERS
started = time.time()
try:
    reader = connection.execute(assignment_query).fetch_record_batch(50000)
    for batch in reader:
        texts = batch.column(batch.schema.get_field_index("document_text")).to_pylist()
        labels = model.predict(vectorizer.transform(texts))
        for label in labels:
            cluster_counts[int(label)] += 1
        output_batch = pa.record_batch(
            [
                batch.column(batch.schema.get_field_index("work_id")),
                pa.array(
                    batch.column(
                        batch.schema.get_field_index("publication_year")
                    ).to_pylist(),
                    type=pa.int16(),
                ),
                batch.column(batch.schema.get_field_index("analytic_field")),
                pa.array(labels, type=pa.int16()),
            ],
            schema=schema,
        )
        writer.write_batch(output_batch)
        assigned_rows += batch.num_rows
        if assigned_rows % 500000 < batch.num_rows:
            print(f"Assigned {assigned_rows:,} works", flush=True)
finally:
    writer.close()

print(
    f"Assigned {assigned_rows:,} works in {time.time() - started:.1f}s",
    flush=True,
)

metadata = {
    "random_seed": RANDOM_SEED,
    "n_features": N_FEATURES,
    "n_clusters": N_CLUSTERS,
    "fit_per_field": FIT_PER_FIELD,
    "assignment_modulus": ASSIGNMENT_MODULUS,
    "minimum_cluster_year_articles": MIN_CLUSTER_YEAR_ARTICLES,
    "training_rows": int(len(fit_frame)),
    "assigned_rows": int(assigned_rows),
    "nonempty_clusters": int(sum(count > 0 for count in cluster_counts)),
    "minimum_nonempty_cluster_size": int(
        min(count for count in cluster_counts if count > 0)
    ),
    "maximum_cluster_size": int(max(cluster_counts)),
    "text_input": "title plus first 1,500 abstract characters",
    "excluded_inputs": [
        "citations",
        "journal name",
        "OpenAlex topic",
        "OpenAlex subfield",
    ],
}
METADATA_PATH.write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")

build_table(
    "text_only_cluster_assignments_six",
    f"""
    SELECT *
    FROM read_parquet('{ASSIGNMENT_PATH}')
    """,
)

scope_values = ["('pooled', 'all', NULL)"]
scope_values.extend(
    f"('{field}', 'field', '{field}')" for field in FIELDS
)
scope_values.extend(
    f"('exclude_{field}', 'exclude', '{field}')" for field in FIELDS
)
scope_sql = ",\n".join(scope_values)

build_table(
    "text_only_coordination_scope_six",
    f"""
    SELECT *
    FROM (VALUES
        {scope_sql}
    ) AS scope(scope_name, scope_type, scope_field)
    """,
)

build_table(
    "text_only_cluster_exposure_six",
    f"""
    WITH sampled_articles AS (
        SELECT
            article.universe,
            assignment.work_id,
            assignment.publication_year,
            assignment.analytic_field,
            assignment.text_cluster_id,
            article.source_id
        FROM text_only_cluster_assignments_six AS assignment
        INNER JOIN analysis_articles AS article USING (work_id)
        WHERE article.source_id IS NOT NULL
    ),
    scoped AS (
        SELECT article.*, scope.scope_name
        FROM sampled_articles AS article
        INNER JOIN text_only_coordination_scope_six AS scope
          ON scope.scope_type = 'all'
          OR (scope.scope_type = 'field'
              AND article.analytic_field = scope.scope_field)
          OR (scope.scope_type = 'exclude'
              AND article.analytic_field <> scope.scope_field)
    ),
    journal_counts AS (
        SELECT
            universe,
            scope_name,
            publication_year,
            text_cluster_id,
            source_id,
            COUNT(*) AS journal_papers
        FROM scoped
        GROUP BY ALL
    ),
    totals AS (
        SELECT
            *,
            SUM(journal_papers) OVER cluster_year AS cluster_year_papers
        FROM journal_counts
        WINDOW cluster_year AS (
            PARTITION BY universe, scope_name,
                         publication_year, text_cluster_id
        )
    )
    SELECT
        universe,
        scope_name,
        publication_year,
        text_cluster_id,
        MAX(cluster_year_papers) AS cell_n,
        1.0 / SUM(POWER(journal_papers * 1.0 / cluster_year_papers, 2))
            AS eff_j,
        LN(
            1.0 / SUM(
                POWER(journal_papers * 1.0 / cluster_year_papers, 2)
            )
        ) AS log_eff_j
    FROM totals
    GROUP BY universe, scope_name, publication_year, text_cluster_id
    HAVING MAX(cluster_year_papers) >= {MIN_CLUSTER_YEAR_ARTICLES}
    """,
)

build_table(
    "text_only_coordination_panel_six",
    """
    WITH family AS (
        SELECT
            article.universe,
            assignment.publication_year,
            assignment.analytic_field,
            assignment.text_cluster_id,
            assignment.work_id AS focal_work_id,
            opportunity.within_possible_pairs,
            opportunity.cross_possible_pairs,
            COALESCE(realized.within_ties, 0) AS within_ties,
            COALESCE(realized.cross_ties, 0) AS cross_ties
        FROM text_only_cluster_assignments_six AS assignment
        INNER JOIN analysis_articles AS article USING (work_id)
        INNER JOIN temporal_coordination_opportunities_six AS opportunity
          ON article.universe = opportunity.universe
         AND assignment.work_id = opportunity.focal_work_id
        LEFT JOIN temporal_coordination_realized_six AS realized
          ON article.universe = realized.universe
         AND assignment.work_id = realized.focal_work_id
    ),
    scoped AS (
        SELECT family.*, scope.scope_name
        FROM family
        INNER JOIN text_only_coordination_scope_six AS scope
          ON scope.scope_type = 'all'
          OR (scope.scope_type = 'field'
              AND family.analytic_field = scope.scope_field)
          OR (scope.scope_type = 'exclude'
              AND family.analytic_field <> scope.scope_field)
    ),
    aggregated AS (
        SELECT
            scoped.universe,
            scoped.scope_name,
            scoped.publication_year,
            scoped.text_cluster_id,
            exposure.log_eff_j,
            COUNT(*) AS focal_families,
            SUM(scoped.within_possible_pairs) AS within_possible_pairs,
            SUM(scoped.cross_possible_pairs) AS cross_possible_pairs,
            SUM(scoped.within_ties) AS within_ties,
            SUM(scoped.cross_ties) AS cross_ties
        FROM scoped
        INNER JOIN text_only_cluster_exposure_six AS exposure USING (
            universe, scope_name, publication_year, text_cluster_id
        )
        GROUP BY scoped.universe, scoped.scope_name,
                 scoped.publication_year, scoped.text_cluster_id,
                 exposure.log_eff_j
    ),
    eligible AS (
        SELECT ROW_NUMBER() OVER () AS panel_id, *
        FROM aggregated
        WHERE within_possible_pairs > 0
          AND cross_possible_pairs > 0
    )
    SELECT
        panel_id,
        universe,
        scope_name,
        publication_year,
        text_cluster_id,
        log_eff_j,
        focal_families,
        0 AS is_cross_journal,
        'within' AS pair_type,
        within_ties AS tie_count,
        within_possible_pairs AS possible_pairs
    FROM eligible
    UNION ALL
    SELECT
        panel_id,
        universe,
        scope_name,
        publication_year,
        text_cluster_id,
        log_eff_j,
        focal_families,
        1 AS is_cross_journal,
        'cross' AS pair_type,
        cross_ties AS tie_count,
        cross_possible_pairs AS possible_pairs
    FROM eligible
    """,
)

panel_path = OUTPUT_DIRECTORY / "text_only_coordination_panel.parquet"
connection.execute(
    f"""
    COPY text_only_coordination_panel_six
    TO '{panel_path}' (FORMAT PARQUET, COMPRESSION ZSTD)
    """
)

violation_count = connection.execute(
    """
    SELECT COUNT(*)
    FROM text_only_coordination_panel_six
    WHERE tie_count > possible_pairs
    """
).fetchone()[0]
if violation_count:
    raise RuntimeError(f"Found {violation_count:,} impossible panel rows")

print(json.dumps(metadata, indent=2), flush=True)
print(
    connection.execute(
        """
        SELECT
            universe,
            scope_name,
            pair_type,
            COUNT(*) AS cluster_years,
            SUM(tie_count) AS ties,
            SUM(possible_pairs) AS possible_pairs,
            1000.0 * SUM(tie_count) / SUM(possible_pairs)
                AS ties_per_1000_opportunities
        FROM text_only_coordination_panel_six
        WHERE scope_name = 'pooled'
        GROUP BY universe, scope_name, pair_type
        ORDER BY universe, pair_type
        """
    ).fetchdf().to_string(index=False),
    flush=True,
)

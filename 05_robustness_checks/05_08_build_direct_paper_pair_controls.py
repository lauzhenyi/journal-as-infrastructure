#!/usr/bin/env python3
"""Build the pair-level journal-boundary robustness sample.

The sample contains ordered pairs of follow-on papers that cite the same focal
paper. It combines SPECTER2 proximity with bibliographic, topical, author, and
organizational overlap measures. The OpenAlex exposure is retained for the main
specification, while the text-only exposure supports a taxonomy-independent
robustness specification.
"""

from __future__ import annotations

import os
from pathlib import Path
import time

import duckdb
import numpy as np
import pyarrow as pa
import pyarrow.parquet as pq


DATABASE_PATH = os.environ.get(
    "JOURNAL_STRUCTURE_DATABASE",
    "/private/tmp/journal_structure_six.duckdb",
)
DATA_ROOT = Path("/Volumes/Extreme SSD/openalex_20260203")
EMBEDDING_ROOT = DATA_ROOT / "embeddings" / "output_embeddings"
OUTPUT_DIRECTORY = Path("results/direct_outcome_gap")
BASE_OUTPUT_PATH = OUTPUT_DIRECTORY / "pair_level_boundary_base.parquet"
OUTPUT_PATH = OUTPUT_DIRECTORY / "pair_level_boundary_pairs.parquet"
OUTPUT_DIRECTORY.mkdir(parents=True, exist_ok=True)

connection = duckdb.connect(DATABASE_PATH)
connection.execute("SET threads=8")
connection.execute("SET memory_limit='32GB'")
connection.execute(
    "SET temp_directory='/private/tmp/duckdb_pair_boundary_tmp'"
)
connection.execute("SET preserve_insertion_order=FALSE")


def build_table(name: str, query: str) -> None:
    """Replace a derived table and report its size and build time."""
    started = time.time()
    connection.execute(f"CREATE OR REPLACE TABLE {name} AS {query}")
    row_count = connection.execute(f"SELECT COUNT(*) FROM {name}").fetchone()[0]
    print(
        f"Built {name}: {row_count:,} rows in {time.time() - started:.1f}s",
        flush=True,
    )


index_glob = str(EMBEDDING_ROOT / "*" / "*" / "index.parquet")
build_table(
    "pair_boundary_embedding_index_six",
    f"""
    WITH requested AS (
        SELECT DISTINCT citing_work_id AS work_id
        FROM semantic_coordination_members_six
    ),
    matched AS (
        SELECT
            requested.work_id,
            embedding_index.row_id,
            REPLACE(
                embedding_index.filename,
                'index.parquet',
                'embeddings.npy'
            ) AS embedding_path
        FROM requested
        INNER JOIN read_parquet(
            '{index_glob}', filename = TRUE
        ) AS embedding_index USING (work_id)
    )
    SELECT
        ROW_NUMBER() OVER (ORDER BY work_id) - 1 AS embedding_position,
        work_id,
        row_id,
        embedding_path
    FROM matched
    """,
)

matched_count = connection.execute(
    "SELECT COUNT(*) FROM pair_boundary_embedding_index_six"
).fetchone()[0]
index_table = connection.execute(
    """
    SELECT embedding_position, row_id, embedding_path
    FROM pair_boundary_embedding_index_six
    ORDER BY embedding_path, row_id
    """
).fetchdf()

embedding_dimension = 768
embedding_matrix = np.empty(
    (matched_count, embedding_dimension), dtype=np.float32
)
started = time.time()
for shard_number, (embedding_path, group) in enumerate(
    index_table.groupby("embedding_path", sort=True), start=1
):
    shard = np.load(embedding_path, mmap_mode="r")
    selected = np.asarray(shard[group["row_id"].to_numpy()], dtype=np.float32)
    norms = np.linalg.norm(selected, axis=1, keepdims=True)
    selected /= np.maximum(norms, np.finfo(np.float32).eps)
    embedding_matrix[group["embedding_position"].to_numpy()] = selected
    if shard_number % 50 == 0:
        print(f"Loaded requested rows from {shard_number} shards", flush=True)

print(
    f"Loaded and normalized {matched_count:,} embeddings in "
    f"{time.time() - started:.1f}s",
    flush=True,
)
del index_table

pair_query = """
    SELECT
        later.universe,
        later.focal_work_id,
        later.citing_work_id AS later_work_id,
        earlier.citing_work_id AS earlier_work_id,
        focal_article.publication_year AS focal_publication_year,
        focal_article.analytic_field,
        focal_article.topic_id AS focal_topic_id,
        focal.text_cluster_id AS focal_text_cluster_id,
        focal_article.log_eff_j AS openalex_log_eff_j,
        exposure.log_eff_j AS text_log_eff_j,
        later.citing_date AS later_date,
        earlier.citing_date AS earlier_date,
        later.citing_source_id AS later_source_id,
        earlier.citing_source_id AS earlier_source_id,
        later.text_cluster_id AS later_text_cluster_id,
        earlier.text_cluster_id AS earlier_text_cluster_id,
        later_meta.citing_topic_id AS later_openalex_topic_id,
        earlier_meta.citing_topic_id AS earlier_openalex_topic_id,
        later_index.embedding_position AS later_embedding_position,
        earlier_index.embedding_position AS earlier_embedding_position,
        CAST(
            later.citing_source_id = earlier.citing_source_id AS INTEGER
        ) AS same_journal,
        CAST(realized.later_work_id IS NOT NULL AS INTEGER) AS tie_count
    FROM semantic_coordination_members_six AS later
    INNER JOIN semantic_coordination_members_six AS earlier
      ON later.universe = earlier.universe
     AND later.focal_work_id = earlier.focal_work_id
     AND later.citing_date > earlier.citing_date
    INNER JOIN pair_boundary_embedding_index_six AS later_index
      ON later.citing_work_id = later_index.work_id
    INNER JOIN pair_boundary_embedding_index_six AS earlier_index
      ON earlier.citing_work_id = earlier_index.work_id
    INNER JOIN analysis_articles AS focal_article
      ON later.universe = focal_article.universe
     AND later.focal_work_id = focal_article.work_id
    INNER JOIN text_only_cluster_assignments_six AS focal
      ON later.focal_work_id = focal.work_id
    INNER JOIN text_only_cluster_exposure_six AS exposure
      ON later.universe = exposure.universe
     AND exposure.scope_name = 'pooled'
     AND focal.publication_year = exposure.publication_year
     AND focal.text_cluster_id = exposure.text_cluster_id
    LEFT JOIN citer_intellectual_metadata_six AS later_meta
      ON later.citing_work_id = later_meta.work_id
    LEFT JOIN citer_intellectual_metadata_six AS earlier_meta
      ON earlier.citing_work_id = earlier_meta.work_id
    LEFT JOIN conversation_pair_horizon_six AS realized
      ON later.universe = realized.universe
     AND later.focal_work_id = realized.focal_work_id
     AND later.citing_work_id = realized.later_work_id
     AND earlier.citing_work_id = realized.earlier_work_id
     AND realized.horizon = 3
"""

reader = connection.execute(pair_query).fetch_record_batch(20000)
writer: pq.ParquetWriter | None = None
pair_count = 0
started = time.time()
for batch in reader:
    later_position = batch.column(
        batch.schema.get_field_index("later_embedding_position")
    ).to_numpy()
    earlier_position = batch.column(
        batch.schema.get_field_index("earlier_embedding_position")
    ).to_numpy()
    cosine_similarity = np.einsum(
        "ij,ij->i",
        embedding_matrix[later_position],
        embedding_matrix[earlier_position],
        optimize=True,
    ).astype(np.float32)

    keep_names = [
        name
        for name in batch.schema.names
        if name not in {"later_embedding_position", "earlier_embedding_position"}
    ]
    keep_arrays = [
        batch.column(batch.schema.get_field_index(name)) for name in keep_names
    ]
    output_batch = pa.RecordBatch.from_arrays(
        keep_arrays + [pa.array(cosine_similarity)],
        names=keep_names + ["cosine_similarity"],
    )
    if writer is None:
        writer = pq.ParquetWriter(
            BASE_OUTPUT_PATH,
            output_batch.schema,
            compression="zstd",
        )
    writer.write_batch(output_batch)
    pair_count += len(output_batch)
    if pair_count % 1_000_000 < len(output_batch):
        print(f"Computed {pair_count:,} pair similarities", flush=True)

if writer is None:
    raise RuntimeError("No pair-level observations were produced")
writer.close()
del embedding_matrix
print(
    f"Computed {pair_count:,} pair similarities in "
    f"{time.time() - started:.1f}s",
    flush=True,
)

build_table(
    "pair_boundary_requested_works_six",
    f"""
    SELECT DISTINCT later_work_id AS work_id
    FROM read_parquet('{BASE_OUTPUT_PATH}')
    UNION
    SELECT DISTINCT earlier_work_id AS work_id
    FROM read_parquet('{BASE_OUTPUT_PATH}')
    """,
)

authorship_glob = str(DATA_ROOT / "analytic_work_authorship" / "*.parquet")
institution_glob = str(
    DATA_ROOT / "analytic_work_author_institution" / "*.parquet"
)
reference_glob = str(DATA_ROOT / "analytic_work_reference" / "*.parquet")
topic_glob = str(DATA_ROOT / "analytic_work_topic" / "*.parquet")

build_table(
    "pair_boundary_author_sets_six",
    f"""
    SELECT
        authorship.work_id,
        LIST(DISTINCT HASH(authorship.author_id)) AS author_ids
    FROM read_parquet('{authorship_glob}') AS authorship
    SEMI JOIN pair_boundary_requested_works_six AS requested
      ON authorship.work_id = requested.work_id
    WHERE authorship.author_id IS NOT NULL
    GROUP BY authorship.work_id
    """,
)

build_table(
    "pair_boundary_organization_sets_six",
    f"""
    SELECT
        affiliation.work_id,
        LIST(DISTINCT HASH(affiliation.institution_id)) FILTER (
            WHERE affiliation.institution_id IS NOT NULL
        ) AS institution_ids,
        LIST(DISTINCT HASH(affiliation.institution_country_code)) FILTER (
            WHERE affiliation.institution_country_code IS NOT NULL
        ) AS country_codes
    FROM read_parquet('{institution_glob}') AS affiliation
    SEMI JOIN pair_boundary_requested_works_six AS requested
      ON affiliation.work_id = requested.work_id
    GROUP BY affiliation.work_id
    """,
)

build_table(
    "pair_boundary_reference_sets_six",
    f"""
    SELECT
        reference.citing_work_id AS work_id,
        LIST(DISTINCT HASH(reference.cited_work_id)) AS reference_ids,
        COUNT(DISTINCT reference.cited_work_id) AS reference_count
    FROM read_parquet('{reference_glob}') AS reference
    SEMI JOIN pair_boundary_requested_works_six AS requested
      ON reference.citing_work_id = requested.work_id
    GROUP BY reference.citing_work_id
    """,
)

build_table(
    "pair_boundary_topic_sets_six",
    f"""
    SELECT
        topic.work_id,
        LIST(DISTINCT HASH(topic.topic_id)) AS topic_ids,
        COUNT(DISTINCT topic.topic_id) AS topic_count
    FROM read_parquet('{topic_glob}') AS topic
    SEMI JOIN pair_boundary_requested_works_six AS requested
      ON topic.work_id = requested.work_id
    WHERE topic.topic_id IS NOT NULL
    GROUP BY topic.work_id
    """,
)

build_table(
    "pair_level_boundary_pairs_six",
    f"""
    WITH enriched AS (
        SELECT
            base.*,
            DATE_DIFF('day', base.earlier_date, base.later_date)
                AS publication_date_distance_days,
            COALESCE(
                LIST_COUNT(LIST_INTERSECT(
                    later_reference.reference_ids,
                    earlier_reference.reference_ids
                )),
                0
            ) AS shared_reference_count,
            COALESCE(later_reference.reference_count, 0)
                AS later_reference_count,
            COALESCE(earlier_reference.reference_count, 0)
                AS earlier_reference_count,
            COALESCE(
                LIST_COUNT(LIST_INTERSECT(
                    later_topic.topic_ids,
                    earlier_topic.topic_ids
                )),
                0
            ) AS shared_topic_count,
            COALESCE(later_topic.topic_count, 0) AS later_topic_count,
            COALESCE(earlier_topic.topic_count, 0) AS earlier_topic_count,
            CAST(COALESCE(LIST_HAS_ANY(
                later_author.author_ids,
                earlier_author.author_ids
            ), FALSE) AS INTEGER) AS author_overlap,
            CAST(COALESCE(LIST_HAS_ANY(
                later_organization.institution_ids,
                earlier_organization.institution_ids
            ), FALSE) AS INTEGER) AS institution_overlap,
            CAST(COALESCE(LIST_HAS_ANY(
                later_organization.country_codes,
                earlier_organization.country_codes
            ), FALSE) AS INTEGER) AS country_overlap
        FROM read_parquet('{BASE_OUTPUT_PATH}') AS base
        LEFT JOIN pair_boundary_author_sets_six AS later_author
          ON base.later_work_id = later_author.work_id
        LEFT JOIN pair_boundary_author_sets_six AS earlier_author
          ON base.earlier_work_id = earlier_author.work_id
        LEFT JOIN pair_boundary_organization_sets_six AS later_organization
          ON base.later_work_id = later_organization.work_id
        LEFT JOIN pair_boundary_organization_sets_six AS earlier_organization
          ON base.earlier_work_id = earlier_organization.work_id
        LEFT JOIN pair_boundary_reference_sets_six AS later_reference
          ON base.later_work_id = later_reference.work_id
        LEFT JOIN pair_boundary_reference_sets_six AS earlier_reference
          ON base.earlier_work_id = earlier_reference.work_id
        LEFT JOIN pair_boundary_topic_sets_six AS later_topic
          ON base.later_work_id = later_topic.work_id
        LEFT JOIN pair_boundary_topic_sets_six AS earlier_topic
          ON base.earlier_work_id = earlier_topic.work_id
    )
    SELECT
        *,
        CASE
            WHEN later_reference_count > 0 AND earlier_reference_count > 0
            THEN shared_reference_count /
                SQRT(later_reference_count * earlier_reference_count)
            ELSE 0.0
        END AS bibliographic_coupling_cosine,
        CASE
            WHEN later_topic_count + earlier_topic_count - shared_topic_count > 0
            THEN shared_topic_count /
                (later_topic_count + earlier_topic_count - shared_topic_count)
            ELSE 0.0
        END AS shared_topic_jaccard
    FROM enriched
    """,
)

connection.execute(
    f"""
    COPY pair_level_boundary_pairs_six
    TO '{OUTPUT_PATH}' (FORMAT PARQUET, COMPRESSION ZSTD)
    """
)

print(
    connection.execute(
        """
        SELECT
            universe,
            COUNT(*) AS pairs,
            SUM(tie_count) AS realized_ties,
            AVG(same_journal) AS same_journal_share,
            AVG(cosine_similarity) AS mean_specter2_cosine,
            AVG(bibliographic_coupling_cosine) AS mean_bibliographic_coupling,
            AVG(author_overlap) AS author_overlap_share,
            AVG(institution_overlap) AS institution_overlap_share,
            AVG(country_overlap) AS country_overlap_share
        FROM pair_level_boundary_pairs_six
        GROUP BY universe
        ORDER BY universe
        """
    ).fetchdf().to_string(index=False),
    flush=True,
)

connection.close()

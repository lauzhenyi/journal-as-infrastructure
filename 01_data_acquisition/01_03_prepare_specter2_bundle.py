#!/usr/bin/env python3
"""
Prepare the English title-and-abstract corpus for SPECTER2 on Google Colab.

Input directories:
    /Volumes/Extreme SSD/openalex_20260203/analytic_work_text
    /Volumes/Extreme SSD/openalex_20260203/analytic_work_field

Output directory:
    /Volumes/Extreme SSD/openalex_20260203/colab_specter2_bundle

Run:
    python prepare_colab_specter2_bundle.py

Dependency:
    python -m pip install duckdb
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path

import duckdb


FIELD_ROWS = [
    (11, "biology"),
    (16, "chemistry"),
    (19, "geology"),
    (25, "materials_science"),
    (27, "medicine"),
    (31, "physics"),
]


def sql_path(path: Path) -> str:
    return str(path).replace("'", "''")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--root",
        type=Path,
        default=Path("/Volumes/Extreme SSD/openalex_20260203"),
    )
    parser.add_argument(
        "--shards-per-year",
        type=int,
        default=16,
    )
    args = parser.parse_args()

    root = args.root
    text_source = root / "analytic_work_text"
    field_source = root / "analytic_work_field"
    output_root = root / "colab_specter2_bundle"

    if not text_source.exists():
        raise FileNotFoundError(text_source)
    if not field_source.exists():
        raise FileNotFoundError(field_source)
    if output_root.exists():
        raise FileExistsError(output_root)

    input_text_dir = output_root / "input_text"
    work_field_dir = output_root / "work_field"
    index_dir = output_root / "index"
    config_dir = output_root / "config"
    reports_dir = output_root / "reports"

    for directory in [
        input_text_dir,
        work_field_dir,
        index_dir,
        config_dir,
        reports_dir,
    ]:
        directory.mkdir(parents=True)

    text_glob = text_source / "**" / "*.parquet"
    field_glob = field_source / "**" / "*.parquet"
    packaged_text_glob = input_text_dir / "**" / "*.parquet"
    packaged_field_glob = work_field_dir / "**" / "*.parquet"
    selected_work_ids = index_dir / "selected_work_ids.parquet"

    threads = max(1, (os.cpu_count() or 4) - 2)
    connection = duckdb.connect()
    connection.execute(f"SET threads = {threads}")
    connection.execute("SET preserve_insertion_order = false")
    connection.execute("SET parquet_metadata_cache = true")
    connection.execute(
        f"SET temp_directory = '{sql_path(root / 'duckdb_temp')}'"
    )

    language_report = reports_dir / "language_by_year.parquet"
    connection.execute(
        f"""
        COPY (
            SELECT
                CAST(publication_year AS SMALLINT) AS publication_year,
                COALESCE(
                    NULLIF(LOWER(TRIM(CAST(language AS VARCHAR))), ''),
                    '__missing__'
                ) AS language,
                COUNT(*) AS n_works
            FROM read_parquet(
                '{sql_path(text_glob)}',
                hive_partitioning = true,
                union_by_name = true
            )
            WHERE publication_year BETWEEN 1995 AND 2025
            GROUP BY
                publication_year,
                language
            ORDER BY
                publication_year,
                n_works DESC
        )
        TO '{sql_path(language_report)}'
        (
            FORMAT parquet,
            COMPRESSION zstd
        )
        """
    )

    connection.execute(
        f"""
        COPY (
            SELECT
                CAST(work_id AS VARCHAR) AS work_id,
                CAST(publication_year AS SMALLINT) AS publication_year,
                CAST(
                    hash(CAST(work_id AS VARCHAR)) % {args.shards_per_year}
                    AS USMALLINT
                ) AS shard_id,
                CAST(title AS VARCHAR) AS title,
                CAST(abstract AS VARCHAR) AS abstract,
                CAST(language AS VARCHAR) AS language,
                md5(
                    CAST(title AS VARCHAR)
                    || CHR(10)
                    || CHR(10)
                    || CAST(abstract AS VARCHAR)
                ) AS text_hash
            FROM read_parquet(
                '{sql_path(text_glob)}',
                hive_partitioning = true,
                union_by_name = true
            )
            WHERE publication_year BETWEEN 1995 AND 2025
              AND LOWER(TRIM(CAST(language AS VARCHAR))) = 'en'
              AND title IS NOT NULL
              AND LENGTH(TRIM(CAST(title AS VARCHAR))) > 0
              AND abstract IS NOT NULL
              AND LENGTH(TRIM(CAST(abstract AS VARCHAR))) > 0
        )
        TO '{sql_path(input_text_dir)}'
        (
            FORMAT parquet,
            COMPRESSION zstd,
            COMPRESSION_LEVEL 3,
            ROW_GROUP_SIZE 122880,
            PARTITION_BY (
                publication_year,
                shard_id
            ),
            OVERWRITE_OR_IGNORE,
            FILENAME_PATTERN 'data_{{i}}'
        )
        """
    )

    connection.execute(
        f"""
        COPY (
            SELECT DISTINCT
                CAST(work_id AS VARCHAR) AS work_id,
                CAST(publication_year AS SMALLINT) AS publication_year
            FROM read_parquet(
                '{sql_path(packaged_text_glob)}',
                hive_partitioning = true,
                union_by_name = true
            )
        )
        TO '{sql_path(selected_work_ids)}'
        (
            FORMAT parquet,
            COMPRESSION zstd
        )
        """
    )

    connection.execute(
        f"""
        COPY (
            SELECT
                CAST(field.work_id AS VARCHAR) AS work_id,
                CAST(field.publication_year AS SMALLINT) AS publication_year,
                CAST(field.field_id AS INTEGER) AS field_id,
                CAST(field.field_name AS VARCHAR) AS field_name,
                CAST(field.analytic_field AS VARCHAR) AS analytic_field
            FROM read_parquet(
                '{sql_path(field_glob)}',
                hive_partitioning = true,
                union_by_name = true
            ) AS field
            INNER JOIN read_parquet(
                '{sql_path(selected_work_ids)}'
            ) AS selected
              ON field.work_id = selected.work_id
             AND field.publication_year = selected.publication_year
            WHERE field.field_id IN (11, 16, 19, 25, 27, 31)
        )
        TO '{sql_path(work_field_dir)}'
        (
            FORMAT parquet,
            COMPRESSION zstd,
            COMPRESSION_LEVEL 3,
            ROW_GROUP_SIZE 122880,
            PARTITION_BY (
                analytic_field,
                publication_year
            ),
            OVERWRITE_OR_IGNORE,
            FILENAME_PATTERN 'data_{{i}}'
        )
        """
    )

    field_year_report = reports_dir / "field_year_counts.parquet"
    connection.execute(
        f"""
        COPY (
            SELECT
                CAST(analytic_field AS VARCHAR) AS analytic_field,
                CAST(publication_year AS SMALLINT) AS publication_year,
                COUNT(DISTINCT work_id) AS n_works
            FROM read_parquet(
                '{sql_path(packaged_field_glob)}',
                hive_partitioning = true,
                union_by_name = true
            )
            GROUP BY
                analytic_field,
                publication_year
            ORDER BY
                analytic_field,
                publication_year
        )
        TO '{sql_path(field_year_report)}'
        (
            FORMAT parquet,
            COMPRESSION zstd
        )
        """
    )

    manifest = reports_dir / "text_shard_manifest.parquet"
    connection.execute(
        f"""
        COPY (
            SELECT
                CAST(publication_year AS SMALLINT) AS publication_year,
                CAST(shard_id AS USMALLINT) AS shard_id,
                COUNT(*) AS n_works,
                MIN(work_id) AS min_work_id,
                MAX(work_id) AS max_work_id
            FROM read_parquet(
                '{sql_path(packaged_text_glob)}',
                hive_partitioning = true,
                union_by_name = true
            )
            GROUP BY
                publication_year,
                shard_id
            ORDER BY
                publication_year,
                shard_id
        )
        TO '{sql_path(manifest)}'
        (
            FORMAT parquet,
            COMPRESSION zstd
        )
        """
    )

    field_values = ",\n".join(
        f"({field_id}, '{analytic_field}')"
        for field_id, analytic_field in FIELD_ROWS
    )
    mke_cells = config_dir / "mke_cells.parquet"
    connection.execute(
        f"""
        COPY (
            SELECT
                CAST(field_id AS INTEGER) AS field_id,
                CAST(analytic_field AS VARCHAR) AS analytic_field,
                CAST(focal_year AS SMALLINT) AS focal_year,
                CAST(focal_year - 5 AS SMALLINT) AS baseline_start_year,
                CAST(focal_year - 1 AS SMALLINT) AS baseline_end_year,
                CAST(focal_year AS SMALLINT) AS outcome_start_year,
                CAST(focal_year + 2 AS SMALLINT) AS outcome_end_year,
                CAST(1000 AS INTEGER) AS sample_size,
                CAST(1000 AS INTEGER) AS n_draws,
                CAST(
                    field_id * 1000000 + focal_year
                    AS BIGINT
                ) AS seed
            FROM (
                VALUES
                {field_values}
            ) AS fields(field_id, analytic_field)
            CROSS JOIN range(2000, 2024) AS years(focal_year)
            ORDER BY
                analytic_field,
                focal_year
        )
        TO '{sql_path(mke_cells)}'
        (
            FORMAT parquet,
            COMPRESSION zstd
        )
        """
    )

    n_text = connection.execute(
        f"""
        SELECT COUNT(*)
        FROM read_parquet(
            '{sql_path(packaged_text_glob)}',
            hive_partitioning = true,
            union_by_name = true
        )
        """
    ).fetchone()[0]

    n_unique_text = connection.execute(
        f"""
        SELECT COUNT(DISTINCT work_id)
        FROM read_parquet(
            '{sql_path(packaged_text_glob)}',
            hive_partitioning = true,
            union_by_name = true
        )
        """
    ).fetchone()[0]

    n_field_rows = connection.execute(
        f"""
        SELECT COUNT(*)
        FROM read_parquet(
            '{sql_path(packaged_field_glob)}',
            hive_partitioning = true,
            union_by_name = true
        )
        """
    ).fetchone()[0]

    config = {
        "corpus": {
            "publication_year_start": 1995,
            "publication_year_end": 2025,
            "language": "en",
            "requires_nonempty_title": True,
            "requires_nonempty_abstract": True,
            "text_fallback": None,
        },
        "specter2": {
            "base_model": "allenai/specter2_base",
            "adapter": "allenai/specter2",
            "max_length": 288,
            "embedding_dimension": 768,
            "output_dtype": "float32",
            "distance": "euclidean",
            "normalize_embeddings": False,
        },
        "mke": {
            "baseline_years": 5,
            "outcome_years": 3,
            "sample_size": 1000,
            "n_draws": 1000,
        },
        "packaging": {
            "shards_per_year": args.shards_per_year,
            "n_text_rows": n_text,
            "n_unique_works": n_unique_text,
            "n_work_field_rows": n_field_rows,
        },
    }

    with (config_dir / "specter2_config.json").open("w", encoding="utf-8") as file:
        json.dump(config, file, ensure_ascii=False, indent=2)

    requirements = """duckdb
numpy
pandas
pyarrow
torch
transformers
adapters
tqdm
"""
    (config_dir / "requirements.txt").write_text(
        requirements,
        encoding="utf-8",
    )

    readme = f"""SPECTER2 Colab bundle

Corpus
------
Language: English only
Years: 1995-2025
Input text: title + abstract
Fallback text: none
Unique works: {n_unique_text:,}
Work-field rows: {n_field_rows:,}

Upload to Colab
---------------
Upload the entire colab_specter2_bundle directory, or synchronize it to
Google Drive or Google Cloud Storage.

Required for embedding:
- input_text/
- config/specter2_config.json
- reports/text_shard_manifest.parquet

Required for paper-level MKE:
- work_field/
- index/selected_work_ids.parquet
- config/mke_cells.parquet
- SPECTER2 embedding outputs

Reports
-------
- reports/language_by_year.parquet
- reports/field_year_counts.parquet
- reports/text_shard_manifest.parquet
"""
    (output_root / "README.txt").write_text(readme, encoding="utf-8")

    connection.close()

    print(f"Created: {output_root}")
    print(f"English text rows: {n_text:,}")
    print(f"Unique works: {n_unique_text:,}")
    print(f"Work-field rows: {n_field_rows:,}")


if __name__ == "__main__":
    main()

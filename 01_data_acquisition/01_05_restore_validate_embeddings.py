#!/usr/bin/env python3
"""
Restore split Google Drive ZIP archives and validate all SPECTER2 outputs.

The script uses fixed absolute paths and can be launched from any directory.
It extracts archives only when no restored embedding files are present.

Dependencies:
    python -m pip install duckdb numpy pandas pyarrow tqdm

Run:
    python /path/to/07_restore_validate_embeddings_v2.py
"""

from __future__ import annotations

import json
import os
import shutil
import zipfile
from collections import defaultdict
from concurrent.futures import ProcessPoolExecutor, as_completed
from datetime import datetime, timezone
from pathlib import Path

import duckdb
import numpy as np
import pandas as pd
import pyarrow.parquet as pq
from tqdm import tqdm


ROOT = Path("/Volumes/Extreme SSD/openalex_20260203")
EMBEDDINGS_ROOT = ROOT / "embeddings"
OUTPUT_ROOT = EMBEDDINGS_ROOT / "output_embeddings"
BUNDLE_ROOT = ROOT / "colab_specter2_bundle"
INPUT_TEXT_ROOT = BUNDLE_ROOT / "input_text"
SELECTED_WORK_IDS_PATH = BUNDLE_ROOT / "index" / "selected_work_ids.parquet"
SOURCE_MANIFEST_PATH = BUNDLE_ROOT / "reports" / "text_shard_manifest.parquet"
CONFIG_PATH = BUNDLE_ROOT / "config" / "specter2_config.json"
REPORTS_ROOT = EMBEDDINGS_ROOT / "reports"
DUCKDB_TEMP = ROOT / "duckdb_temp"

VALIDATION_PATH = REPORTS_ROOT / "embedding_validation.parquet"
SHARD_MANIFEST_PATH = REPORTS_ROOT / "embedding_shard_manifest.parquet"
SUMMARY_PATH = REPORTS_ROOT / "embedding_validation_summary.json"

ZIP_PATTERN = "output_embeddings-*.zip"
REQUIRED_FILENAMES = {"embeddings.npy", "index.parquet", "metadata.json"}
FINITE_CHECK_ROWS = 8192
SCRIPT_VERSION = "v2"
VALIDATION_WORKERS = max(1, (os.cpu_count() or 4) - 2)


def sql_path(path: Path) -> str:
    return str(path).replace("'", "''")


def parse_partition_value(path: Path, key: str) -> int:
    prefix = f"{key}="
    for part in path.parts:
        if part.startswith(prefix):
            return int(part[len(prefix) :])
    raise ValueError(f"Missing {key} partition in {path}")


def normalized_archive_member(info: zipfile.ZipInfo) -> Path | None:
    if info.is_dir():
        return None

    parts = Path(info.filename).parts
    year_index = next(
        (index for index, part in enumerate(parts) if part.startswith("publication_year=")),
        None,
    )
    if year_index is None:
        return None

    relative = Path(*parts[year_index:])
    if len(relative.parts) != 3:
        return None
    if not relative.parts[1].startswith("shard_id="):
        return None
    if relative.name not in REQUIRED_FILENAMES:
        return None
    if ".." in relative.parts:
        raise ValueError(f"Unsafe archive member: {info.filename}")
    return relative


def restored_files_exist() -> bool:
    if not OUTPUT_ROOT.exists():
        return False
    return any(OUTPUT_ROOT.glob("publication_year=*/shard_id=*/embeddings.npy"))


def build_archive_inventory(zip_paths: list[Path]) -> dict[Path, tuple[Path, zipfile.ZipInfo]]:
    inventory: dict[Path, tuple[Path, zipfile.ZipInfo]] = {}
    duplicate_count = 0

    for zip_path in tqdm(zip_paths, desc="Reading ZIP inventories", unit="zip"):
        with zipfile.ZipFile(zip_path) as archive:
            for info in archive.infolist():
                relative = normalized_archive_member(info)
                if relative is None:
                    continue

                existing = inventory.get(relative)
                if existing is None:
                    inventory[relative] = (zip_path, info)
                    continue

                existing_info = existing[1]
                if (
                    existing_info.CRC != info.CRC
                    or existing_info.file_size != info.file_size
                ):
                    raise ValueError(
                        "Conflicting files across ZIP archives: "
                        f"{relative}\n"
                        f"  {existing[0]}: CRC={existing_info.CRC}, size={existing_info.file_size}\n"
                        f"  {zip_path}: CRC={info.CRC}, size={info.file_size}"
                    )
                duplicate_count += 1

    if not inventory:
        raise FileNotFoundError(
            f"No publication_year=*/shard_id=* embedding files found in {EMBEDDINGS_ROOT}"
        )

    print(f"Unique files in ZIP archives: {len(inventory):,}")
    print(f"Identical duplicate archive members: {duplicate_count:,}")
    return inventory


def extract_inventory(inventory: dict[Path, tuple[Path, zipfile.ZipInfo]]) -> None:
    OUTPUT_ROOT.mkdir(parents=True, exist_ok=True)
    by_archive: dict[Path, list[tuple[Path, zipfile.ZipInfo]]] = defaultdict(list)
    total_bytes = 0

    for relative, (zip_path, info) in inventory.items():
        by_archive[zip_path].append((relative, info))
        total_bytes += info.file_size

    with tqdm(
        total=total_bytes,
        desc="Extracting embeddings",
        unit="B",
        unit_scale=True,
        unit_divisor=1024,
    ) as progress:
        for zip_path in sorted(by_archive):
            with zipfile.ZipFile(zip_path) as archive:
                for relative, info in sorted(by_archive[zip_path], key=lambda item: str(item[0])):
                    destination = OUTPUT_ROOT / relative
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    temporary = destination.with_name(destination.name + ".partial")

                    with archive.open(info) as source, temporary.open("wb") as target:
                        while True:
                            block = source.read(8 * 1024 * 1024)
                            if not block:
                                break
                            target.write(block)
                            progress.update(len(block))

                    os.replace(temporary, destination)


def validate_finite(array: np.ndarray) -> bool:
    for start in range(0, array.shape[0], FINITE_CHECK_ROWS):
        end = min(start + FINITE_CHECK_ROWS, array.shape[0])
        if not np.isfinite(array[start:end]).all():
            return False
    return True


def validate_shard(shard_dir: Path, source_manifest_rows: int) -> dict:
    year = parse_partition_value(shard_dir, "publication_year")
    shard_id = parse_partition_value(shard_dir, "shard_id")
    embedding_path = shard_dir / "embeddings.npy"
    index_path = shard_dir / "index.parquet"
    metadata_path = shard_dir / "metadata.json"

    errors: list[str] = []
    warnings: list[str] = []
    for path in [embedding_path, index_path, metadata_path]:
        if not path.exists():
            errors.append(f"missing {path.name}")

    metadata: dict = {}
    metadata_rows = -1
    index_rows = -1
    embedding_rows = -1
    embedding_columns = -1
    embedding_dtype = None

    if metadata_path.exists():
        with metadata_path.open("r", encoding="utf-8") as file:
            metadata = json.load(file)
        metadata_rows = int(metadata.get("n_output_rows", -1))
        if metadata.get("status") != "completed":
            errors.append(f"metadata status={metadata.get('status')}")
        if int(metadata.get("publication_year", -1)) != year:
            errors.append("metadata publication_year mismatch")
        if int(metadata.get("shard_id", -1)) != shard_id:
            errors.append("metadata shard_id mismatch")
        if metadata.get("embedding_dtype") != "float32":
            errors.append("metadata embedding_dtype mismatch")

    if index_path.exists():
        parquet_file = pq.ParquetFile(index_path)
        index_rows = int(parquet_file.metadata.num_rows)
        table = parquet_file.read(
            columns=["row_id", "work_id", "publication_year", "text_hash"],
        )
        row_ids = table.column("row_id").to_numpy(zero_copy_only=False)
        work_ids = table.column("work_id").to_pandas()
        years = table.column("publication_year").to_numpy(zero_copy_only=False)
        text_hashes = table.column("text_hash")

        if index_rows > 0 and not np.array_equal(row_ids, np.arange(index_rows, dtype=row_ids.dtype)):
            errors.append("row_id is not contiguous from zero")
        if work_ids.isna().any():
            errors.append("null work_id")
        if work_ids.duplicated().any():
            errors.append("duplicate work_id within shard")
        if index_rows > 0 and not np.all(years == year):
            errors.append("index publication_year mismatch")
        if text_hashes.null_count > 0:
            errors.append("null text_hash")

    if embedding_path.exists():
        array = np.load(embedding_path, mmap_mode="r")
        if array.ndim != 2:
            errors.append(f"embedding array ndim={array.ndim}")
        else:
            embedding_rows = int(array.shape[0])
            embedding_columns = int(array.shape[1])
        embedding_dtype = str(array.dtype)
        if embedding_columns != 768:
            errors.append(f"embedding dimension={embedding_columns}")
        if embedding_dtype != "float32":
            errors.append(f"embedding dtype={embedding_dtype}")
        if array.ndim == 2 and not validate_finite(array):
            errors.append("non-finite embedding values")
        del array

    internal_row_counts = {metadata_rows, index_rows, embedding_rows}
    if len(internal_row_counts) != 1:
        errors.append(
            "internal row count mismatch: "
            f"metadata={metadata_rows}, index={index_rows}, "
            f"embeddings={embedding_rows}"
        )

    source_manifest_row_match = (
        source_manifest_rows < 0
        or index_rows < 0
        or source_manifest_rows == index_rows
    )
    if not source_manifest_row_match:
        warnings.append(
            "source manifest shard allocation differs: "
            f"source_manifest={source_manifest_rows}, output={index_rows}"
        )

    return {
        "publication_year": year,
        "shard_id": shard_id,
        "valid": len(errors) == 0,
        "errors": " | ".join(errors),
        "warnings": " | ".join(warnings),
        "source_manifest_rows": source_manifest_rows,
        "source_manifest_row_match": source_manifest_row_match,
        "metadata_rows": metadata_rows,
        "index_rows": index_rows,
        "embedding_rows": embedding_rows,
        "embedding_columns": embedding_columns,
        "embedding_dtype": embedding_dtype,
        "embedding_path": str(embedding_path),
        "index_path": str(index_path),
        "metadata_path": str(metadata_path),
        "embedding_bytes": embedding_path.stat().st_size if embedding_path.exists() else 0,
        "index_bytes": index_path.stat().st_size if index_path.exists() else 0,
        "metadata_bytes": metadata_path.stat().st_size if metadata_path.exists() else 0,
    }


def validate_shard_worker(shard_dir: str, source_manifest_rows: int) -> dict:
    return validate_shard(Path(shard_dir), source_manifest_rows)


def run_global_checks(expected_total_rows: int) -> dict:
    index_glob = OUTPUT_ROOT / "publication_year=*" / "shard_id=*" / "index.parquet"
    input_glob = INPUT_TEXT_ROOT / "**" / "*.parquet"

    DUCKDB_TEMP.mkdir(parents=True, exist_ok=True)
    connection = duckdb.connect()
    connection.execute(f"SET threads = {VALIDATION_WORKERS}")
    connection.execute("SET preserve_insertion_order = false")
    connection.execute("SET parquet_metadata_cache = true")
    connection.execute(f"SET temp_directory = '{sql_path(DUCKDB_TEMP)}'")

    connection.execute(
        f"""
        CREATE TEMP VIEW embedding_index AS
        SELECT
            CAST(work_id AS VARCHAR) AS work_id,
            CAST(publication_year AS SMALLINT) AS publication_year,
            CAST(text_hash AS VARCHAR) AS text_hash
        FROM read_parquet(
            '{sql_path(index_glob)}',
            hive_partitioning = false,
            union_by_name = true
        )
        """
    )
    connection.execute(
        f"""
        CREATE TEMP VIEW selected_work_ids AS
        SELECT
            CAST(work_id AS VARCHAR) AS work_id,
            CAST(publication_year AS SMALLINT) AS publication_year
        FROM read_parquet('{sql_path(SELECTED_WORK_IDS_PATH)}')
        """
    )
    connection.execute(
        f"""
        CREATE TEMP VIEW input_text AS
        SELECT
            CAST(work_id AS VARCHAR) AS work_id,
            CAST(publication_year AS SMALLINT) AS publication_year,
            CAST(text_hash AS VARCHAR) AS text_hash
        FROM read_parquet(
            '{sql_path(input_glob)}',
            hive_partitioning = true,
            union_by_name = true
        )
        """
    )

    print("Running global work coverage and text-hash checks...")
    print("[1/5] Counting embedding index rows...")
    total_rows = int(connection.execute("SELECT COUNT(*) FROM embedding_index").fetchone()[0])
    print("[2/5] Checking duplicate work IDs...")
    duplicate_work_ids = int(
        connection.execute(
            """
            SELECT COUNT(*)
            FROM (
                SELECT work_id
                FROM embedding_index
                GROUP BY work_id
                HAVING COUNT(*) > 1
            )
            """
        ).fetchone()[0]
    )
    print("[3/5] Checking selected works missing from embeddings...")
    missing_from_embeddings = int(
        connection.execute(
            """
            SELECT COUNT(*)
            FROM selected_work_ids AS selected
            ANTI JOIN embedding_index AS embedded
              ON selected.work_id = embedded.work_id
             AND selected.publication_year = embedded.publication_year
            """
        ).fetchone()[0]
    )
    print("[4/5] Checking unexpected works in embeddings...")
    extra_in_embeddings = int(
        connection.execute(
            """
            SELECT COUNT(*)
            FROM embedding_index AS embedded
            ANTI JOIN selected_work_ids AS selected
              ON embedded.work_id = selected.work_id
             AND embedded.publication_year = selected.publication_year
            """
        ).fetchone()[0]
    )
    print("[5/5] Checking text hashes against the source corpus...")
    text_hash_mismatches = int(
        connection.execute(
            """
            SELECT COUNT(*)
            FROM embedding_index AS embedded
            INNER JOIN input_text AS source
              ON embedded.work_id = source.work_id
             AND embedded.publication_year = source.publication_year
            WHERE embedded.text_hash IS DISTINCT FROM source.text_hash
            """
        ).fetchone()[0]
    )
    connection.close()

    return {
        "total_rows": total_rows,
        "expected_total_rows": expected_total_rows,
        "duplicate_work_ids": duplicate_work_ids,
        "missing_from_embeddings": missing_from_embeddings,
        "extra_in_embeddings": extra_in_embeddings,
        "text_hash_mismatches": text_hash_mismatches,
        "valid": (
            total_rows == expected_total_rows
            and duplicate_work_ids == 0
            and missing_from_embeddings == 0
            and extra_in_embeddings == 0
            and text_hash_mismatches == 0
        ),
    }


def main() -> None:
    for path in [EMBEDDINGS_ROOT, BUNDLE_ROOT, SOURCE_MANIFEST_PATH, CONFIG_PATH]:
        if not path.exists():
            raise FileNotFoundError(path)

    REPORTS_ROOT.mkdir(parents=True, exist_ok=True)

    if restored_files_exist():
        print(f"Restored embedding files already exist: {OUTPUT_ROOT}")
        print("ZIP extraction skipped. Validation will run on the existing files.")
    else:
        zip_paths = sorted(EMBEDDINGS_ROOT.glob(ZIP_PATTERN))
        if not zip_paths:
            raise FileNotFoundError(f"No ZIP archives matching {EMBEDDINGS_ROOT / ZIP_PATTERN}")
        print(f"ZIP archives found: {len(zip_paths):,}")
        inventory = build_archive_inventory(zip_paths)
        extract_inventory(inventory)
        print(f"Extraction completed: {OUTPUT_ROOT}")

    source_manifest = pd.read_parquet(SOURCE_MANIFEST_PATH)
    source_manifest = source_manifest.sort_values(
        ["publication_year", "shard_id"],
        ignore_index=True,
    )
    expected = {
        (int(row.publication_year), int(row.shard_id)): int(row.n_works)
        for row in source_manifest.itertuples(index=False)
    }

    shard_dirs = sorted(OUTPUT_ROOT.glob("publication_year=*/shard_id=*"))
    actual_keys = {
        (
            parse_partition_value(path, "publication_year"),
            parse_partition_value(path, "shard_id"),
        )
        for path in shard_dirs
    }
    expected_keys = set(expected)

    missing_shards = sorted(expected_keys - actual_keys)
    extra_shards = sorted(actual_keys - expected_keys)
    if missing_shards:
        print(f"Missing shard directories: {missing_shards[:20]}")
    if extra_shards:
        print(f"Unexpected shard directories: {extra_shards[:20]}")

    validation_jobs = []
    for shard_dir in shard_dirs:
        key = (
            parse_partition_value(shard_dir, "publication_year"),
            parse_partition_value(shard_dir, "shard_id"),
        )
        validation_jobs.append((str(shard_dir), expected.get(key, -1)))

    print(
        f"Validating {len(validation_jobs):,} shards with "
        f"{VALIDATION_WORKERS:,} worker processes "
        f"({os.cpu_count() or 4} total logical cores minus 2)."
    )
    validation_rows = []
    with ProcessPoolExecutor(max_workers=VALIDATION_WORKERS) as executor:
        futures = {
            executor.submit(validate_shard_worker, shard_dir, expected_rows): shard_dir
            for shard_dir, expected_rows in validation_jobs
        }
        with tqdm(
            total=len(futures),
            desc="Validating shards",
            unit="shard",
        ) as progress:
            for future in as_completed(futures):
                shard_dir = futures[future]
                try:
                    validation_rows.append(future.result())
                except Exception as error:
                    for pending in futures:
                        pending.cancel()
                    raise RuntimeError(
                        f"Shard validation worker failed for {shard_dir}"
                    ) from error
                progress.update(1)

    validation = pd.DataFrame(validation_rows).sort_values(
        ["publication_year", "shard_id"],
        ignore_index=True,
    )
    validation.to_parquet(VALIDATION_PATH, index=False, compression="zstd")
    validation.to_parquet(SHARD_MANIFEST_PATH, index=False, compression="zstd")

    expected_total_rows = int(source_manifest["n_works"].sum())
    global_checks = run_global_checks(expected_total_rows)
    all_shards_valid = bool(len(validation) > 0 and validation["valid"].all())
    source_manifest_mismatch_count = int(
        (~validation["source_manifest_row_match"]).sum()
    ) if len(validation) else 0
    run_complete = (
        not missing_shards
        and not extra_shards
        and len(validation) == len(expected)
        and all_shards_valid
        and global_checks["valid"]
    )

    summary = {
        "script_version": SCRIPT_VERSION,
        "run_complete": run_complete,
        "output_root": str(OUTPUT_ROOT),
        "expected_shards": len(expected),
        "actual_shards": len(validation),
        "valid_shards": int(validation["valid"].sum()) if len(validation) else 0,
        "source_manifest_shard_row_mismatches": source_manifest_mismatch_count,
        "source_manifest_shard_rows_are_informational": True,
        "missing_shards": missing_shards,
        "extra_shards": extra_shards,
        "embedding_dimension": 768,
        "global_checks": global_checks,
        "validated_at_utc": datetime.now(timezone.utc).isoformat(),
    }
    with SUMMARY_PATH.open("w", encoding="utf-8") as file:
        json.dump(summary, file, ensure_ascii=False, indent=2)

    if source_manifest_mismatch_count:
        print(
            "WARNING: "
            f"{source_manifest_mismatch_count:,} shard row counts differ from "
            "the local source manifest. This is treated as a shard-allocation "
            "difference because global work coverage and text hashes are checked "
            "separately."
        )

    print(json.dumps(summary, ensure_ascii=False, indent=2))
    print(f"Shard validation report: {VALIDATION_PATH}")
    print(f"Validation summary: {SUMMARY_PATH}")

    if not run_complete:
        invalid = validation.loc[~validation["valid"]]
        if len(invalid):
            print(invalid.head(20).to_string(index=False))
        raise RuntimeError("Embedding restoration or validation failed.")


if __name__ == "__main__":
    main()

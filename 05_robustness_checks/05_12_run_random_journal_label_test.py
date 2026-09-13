#!/usr/bin/env python3
"""Run exact-count journal-label permutations for follow-on paper pairs.

Journal labels are shuffled among works inside the relevant intellectual
cluster-by-publication-year stratum. This preserves the complete journal-count
vector in every stratum. The statistic is the same-journal-by-log(EffJ)
interaction from a linear probability model with focal-family fixed effects.
"""

from __future__ import annotations

from pathlib import Path

import numba
import numpy as np
import pandas as pd
import pyarrow.parquet as pq


INPUT_PATH = Path("results/direct_outcome_gap/pair_level_boundary_pairs.parquet")
OUTPUT_DIRECTORY = Path("results/direct_outcome_gap")
DRAW_OUTPUT_PATH = OUTPUT_DIRECTORY / "journal_label_permutation_draws.csv"
SUMMARY_OUTPUT_PATH = OUTPUT_DIRECTORY / "journal_label_permutation_summary.csv"
BOUNDARY_DRAW_OUTPUT_PATH = (
    OUTPUT_DIRECTORY / "journal_label_permutation_boundary_draws.csv"
)
BOUNDARY_SUMMARY_OUTPUT_PATH = (
    OUTPUT_DIRECTORY / "journal_label_permutation_boundary_summary.csv"
)
PERMUTATIONS = 1000
BASE_SEED = 20260827


@numba.njit(cache=True)
def interaction_coefficient(
    same_journal: np.ndarray,
    pair_family: np.ndarray,
    y_within: np.ndarray,
    family_size: np.ndarray,
    family_exposure: np.ndarray,
) -> float:
    """Return the family-fixed-effect interaction coefficient."""
    family_count = np.zeros(family_size.size, dtype=np.float64)
    family_y_sum = np.zeros(family_size.size, dtype=np.float64)
    for pair_index in range(pair_family.size):
        if same_journal[pair_index]:
            family_index = pair_family[pair_index]
            family_count[family_index] += 1.0
            family_y_sum[family_index] += y_within[pair_index]

    a00 = 0.0
    a01 = 0.0
    a11 = 0.0
    b0 = 0.0
    b1 = 0.0
    for family_index in range(family_size.size):
        same_count = family_count[family_index]
        if same_count == 0.0 or same_count == family_size[family_index]:
            continue
        within_variation = same_count - (
            same_count * same_count / family_size[family_index]
        )
        exposure = family_exposure[family_index]
        outcome_crossproduct = family_y_sum[family_index]
        a00 += within_variation
        a01 += exposure * within_variation
        a11 += exposure * exposure * within_variation
        b0 += outcome_crossproduct
        b1 += exposure * outcome_crossproduct

    determinant = a00 * a11 - a01 * a01
    return (a00 * b1 - a01 * b0) / determinant


@numba.njit(cache=True)
def boundary_coefficient(
    same_journal: np.ndarray,
    pair_family: np.ndarray,
    y_within: np.ndarray,
    family_size: np.ndarray,
    family_exposure_centered: np.ndarray,
) -> float:
    """Return the same-journal coefficient at the median EffJ."""
    family_count = np.zeros(family_size.size, dtype=np.float64)
    family_y_sum = np.zeros(family_size.size, dtype=np.float64)
    for pair_index in range(pair_family.size):
        if same_journal[pair_index]:
            family_index = pair_family[pair_index]
            family_count[family_index] += 1.0
            family_y_sum[family_index] += y_within[pair_index]

    a00 = 0.0
    a01 = 0.0
    a11 = 0.0
    b0 = 0.0
    b1 = 0.0
    for family_index in range(family_size.size):
        same_count = family_count[family_index]
        if same_count == 0.0 or same_count == family_size[family_index]:
            continue
        within_variation = same_count - (
            same_count * same_count / family_size[family_index]
        )
        exposure = family_exposure_centered[family_index]
        outcome_crossproduct = family_y_sum[family_index]
        a00 += within_variation
        a01 += exposure * within_variation
        a11 += exposure * exposure * within_variation
        b0 += outcome_crossproduct
        b1 += exposure * outcome_crossproduct

    determinant = a00 * a11 - a01 * a01
    return (a11 * b0 - a01 * b1) / determinant


@numba.njit(parallel=True, cache=True)
def permutation_coefficients(
    permutations: int,
    base_seed: int,
    base_labels: np.ndarray,
    grouped_work_indices: np.ndarray,
    group_offsets: np.ndarray,
    pair_later_work: np.ndarray,
    pair_earlier_work: np.ndarray,
    pair_family: np.ndarray,
    y_within: np.ndarray,
    family_size: np.ndarray,
    family_exposure: np.ndarray,
) -> np.ndarray:
    """Shuffle exact label multisets and estimate each interaction."""
    output = np.empty(permutations, dtype=np.float64)
    for permutation_index in numba.prange(permutations):
        np.random.seed(base_seed + permutation_index)
        labels = base_labels.copy()
        for group_index in range(group_offsets.size - 1):
            start = group_offsets[group_index]
            stop = group_offsets[group_index + 1]
            for position in range(stop - 1, start, -1):
                swap_position = start + np.random.randint(position - start + 1)
                left_work = grouped_work_indices[position]
                right_work = grouped_work_indices[swap_position]
                temporary_label = labels[left_work]
                labels[left_work] = labels[right_work]
                labels[right_work] = temporary_label

        same_journal = np.empty(pair_family.size, dtype=np.bool_)
        for pair_index in range(pair_family.size):
            same_journal[pair_index] = (
                labels[pair_later_work[pair_index]]
                == labels[pair_earlier_work[pair_index]]
            )
        output[permutation_index] = interaction_coefficient(
            same_journal,
            pair_family,
            y_within,
            family_size,
            family_exposure,
        )
    return output


@numba.njit(parallel=True, cache=True)
def permutation_boundary_coefficients(
    permutations: int,
    base_seed: int,
    base_labels: np.ndarray,
    grouped_work_indices: np.ndarray,
    group_offsets: np.ndarray,
    pair_later_work: np.ndarray,
    pair_earlier_work: np.ndarray,
    pair_family: np.ndarray,
    y_within: np.ndarray,
    family_size: np.ndarray,
    family_exposure_centered: np.ndarray,
) -> np.ndarray:
    """Shuffle exact label multisets and estimate the boundary coefficient."""
    output = np.empty(permutations, dtype=np.float64)
    for permutation_index in numba.prange(permutations):
        np.random.seed(base_seed + permutation_index)
        labels = base_labels.copy()
        for group_index in range(group_offsets.size - 1):
            start = group_offsets[group_index]
            stop = group_offsets[group_index + 1]
            for position in range(stop - 1, start, -1):
                swap_position = start + np.random.randint(position - start + 1)
                left_work = grouped_work_indices[position]
                right_work = grouped_work_indices[swap_position]
                temporary_label = labels[left_work]
                labels[left_work] = labels[right_work]
                labels[right_work] = temporary_label

        same_journal = np.empty(pair_family.size, dtype=np.bool_)
        for pair_index in range(pair_family.size):
            same_journal[pair_index] = (
                labels[pair_later_work[pair_index]]
                == labels[pair_earlier_work[pair_index]]
            )
        output[permutation_index] = boundary_coefficient(
            same_journal,
            pair_family,
            y_within,
            family_size,
            family_exposure_centered,
        )
    return output


def factorize(values: pd.Series) -> tuple[np.ndarray, np.ndarray]:
    """Return integer codes and unique labels with no missing code."""
    codes, uniques = pd.factorize(values.fillna("missing"), sort=True)
    return codes.astype(np.int64), np.asarray(uniques)


def prepare_universe(
    data: pd.DataFrame,
    exposure_column: str,
    stratum_kind: str,
) -> dict[str, np.ndarray]:
    """Encode one universe for exact-count permutations."""
    later = data[
        [
            "later_work_id",
            "later_source_id",
            "later_date",
            "later_text_cluster_id",
            "later_openalex_topic_id",
        ]
    ].rename(
        columns={
            "later_work_id": "work_id",
            "later_source_id": "source_id",
            "later_date": "publication_date",
            "later_text_cluster_id": "text_cluster_id",
            "later_openalex_topic_id": "openalex_topic_id",
        }
    )
    earlier = data[
        [
            "earlier_work_id",
            "earlier_source_id",
            "earlier_date",
            "earlier_text_cluster_id",
            "earlier_openalex_topic_id",
        ]
    ].rename(
        columns={
            "earlier_work_id": "work_id",
            "earlier_source_id": "source_id",
            "earlier_date": "publication_date",
            "earlier_text_cluster_id": "text_cluster_id",
            "earlier_openalex_topic_id": "openalex_topic_id",
        }
    )
    work_table = pd.concat([later, earlier], ignore_index=True).drop_duplicates(
        "work_id"
    )
    work_table = work_table.reset_index(drop=True)
    work_table["publication_year"] = pd.to_datetime(
        work_table["publication_date"]
    ).dt.year.astype(str)

    work_index = pd.Series(
        np.arange(len(work_table), dtype=np.int64),
        index=work_table["work_id"],
    )
    pair_later_work = work_index.loc[data["later_work_id"]].to_numpy()
    pair_earlier_work = work_index.loc[data["earlier_work_id"]].to_numpy()
    base_labels, _ = factorize(work_table["source_id"])

    if stratum_kind == "text_cluster_year":
        stratum_value = (
            work_table["text_cluster_id"].astype("string").fillna("missing")
            + "::"
            + work_table["publication_year"]
        )
    elif stratum_kind == "openalex_topic_year":
        stratum_value = (
            work_table["openalex_topic_id"].astype("string").fillna("missing")
            + "::"
            + work_table["publication_year"]
        )
    else:
        raise ValueError(f"Unknown stratum kind: {stratum_kind}")
    stratum_codes, _ = factorize(stratum_value)

    sortable = pd.DataFrame(
        {
            "work_index": np.arange(len(work_table), dtype=np.int64),
            "stratum": stratum_codes,
        }
    ).sort_values(["stratum", "work_index"])
    grouped_work_indices = sortable["work_index"].to_numpy(dtype=np.int64)
    sorted_strata = sortable["stratum"].to_numpy(dtype=np.int64)
    group_starts = np.r_[0, 1 + np.flatnonzero(np.diff(sorted_strata))]
    group_offsets = np.r_[group_starts, len(grouped_work_indices)].astype(np.int64)

    pair_family, family_labels = factorize(data["focal_work_id"])
    family_size = np.bincount(pair_family).astype(np.float64)
    outcome = data["tie_count"].to_numpy(dtype=np.float64)
    family_outcome_sum = np.bincount(pair_family, weights=outcome)
    y_within = outcome - family_outcome_sum[pair_family] / family_size[pair_family]
    family_exposure = (
        data.groupby("focal_work_id", sort=True)[exposure_column]
        .first()
        .reindex(family_labels)
        .to_numpy(dtype=np.float64)
    )

    return {
        "base_labels": base_labels,
        "grouped_work_indices": grouped_work_indices,
        "group_offsets": group_offsets,
        "pair_later_work": pair_later_work,
        "pair_earlier_work": pair_earlier_work,
        "pair_family": pair_family,
        "y_within": y_within,
        "family_size": family_size,
        "family_exposure": family_exposure,
    }


columns = [
    "universe",
    "focal_work_id",
    "later_work_id",
    "earlier_work_id",
    "later_date",
    "earlier_date",
    "later_source_id",
    "earlier_source_id",
    "later_text_cluster_id",
    "earlier_text_cluster_id",
    "later_openalex_topic_id",
    "earlier_openalex_topic_id",
    "openalex_log_eff_j",
    "text_log_eff_j",
    "same_journal",
    "tie_count",
]
pair_data = pq.read_table(INPUT_PATH, columns=columns).to_pandas()

draw_tables: list[pd.DataFrame] = []
summary_rows: list[dict[str, object]] = []
boundary_draw_tables: list[pd.DataFrame] = []
boundary_summary_rows: list[dict[str, object]] = []
designs = [
    ("openalex_log_eff_j", "openalex_topic_year"),
    ("text_log_eff_j", "text_cluster_year"),
]

for universe_name in ["full", "scimago"]:
    universe_data = pair_data.loc[pair_data["universe"] == universe_name].copy()
    for design_index, (exposure_column, stratum_kind) in enumerate(designs):
        encoded = prepare_universe(
            universe_data,
            exposure_column,
            stratum_kind,
        )
        actual_same = universe_data["same_journal"].to_numpy(dtype=np.bool_)
        actual_coefficient = interaction_coefficient(
            actual_same,
            encoded["pair_family"],
            encoded["y_within"],
            encoded["family_size"],
            encoded["family_exposure"],
        )
        seed = BASE_SEED + 10000 * design_index + (
            100000 if universe_name == "scimago" else 0
        )
        permuted = permutation_coefficients(
            PERMUTATIONS,
            seed,
            encoded["base_labels"],
            encoded["grouped_work_indices"],
            encoded["group_offsets"],
            encoded["pair_later_work"],
            encoded["pair_earlier_work"],
            encoded["pair_family"],
            encoded["y_within"],
            encoded["family_size"],
            encoded["family_exposure"],
        )
        centered_exposure = encoded["family_exposure"] - np.median(
            encoded["family_exposure"]
        )
        actual_boundary_coefficient = boundary_coefficient(
            actual_same,
            encoded["pair_family"],
            encoded["y_within"],
            encoded["family_size"],
            centered_exposure,
        )
        permuted_boundary = permutation_boundary_coefficients(
            PERMUTATIONS,
            seed,
            encoded["base_labels"],
            encoded["grouped_work_indices"],
            encoded["group_offsets"],
            encoded["pair_later_work"],
            encoded["pair_earlier_work"],
            encoded["pair_family"],
            encoded["y_within"],
            encoded["family_size"],
            centered_exposure,
        )
        empirical_p_upper = (1 + np.sum(permuted >= actual_coefficient)) / (
            PERMUTATIONS + 1
        )
        empirical_p_two_sided = (
            1
            + np.sum(
                np.abs(permuted - np.mean(permuted))
                >= abs(actual_coefficient - np.mean(permuted))
            )
        ) / (PERMUTATIONS + 1)
        draw_tables.append(
            pd.DataFrame(
                {
                    "universe": universe_name,
                    "exposure": exposure_column,
                    "shuffle_stratum": stratum_kind,
                    "permutation": np.arange(1, PERMUTATIONS + 1),
                    "interaction_coefficient": permuted,
                    "interaction_pp_for_effj_doubling":
                        100 * np.log(2) * permuted,
                }
            )
        )
        summary_rows.append(
            {
                "universe": universe_name,
                "exposure": exposure_column,
                "shuffle_stratum": stratum_kind,
                "permutations": PERMUTATIONS,
                "actual_interaction_coefficient": actual_coefficient,
                "actual_interaction_pp_for_effj_doubling":
                    100 * np.log(2) * actual_coefficient,
                "permutation_mean": float(np.mean(permuted)),
                "permutation_sd": float(np.std(permuted, ddof=1)),
                "permutation_q025": float(np.quantile(permuted, 0.025)),
                "permutation_q975": float(np.quantile(permuted, 0.975)),
                "empirical_p_upper": empirical_p_upper,
                "empirical_p_two_sided": empirical_p_two_sided,
                "pairs": len(universe_data),
                "works": len(encoded["base_labels"]),
                "focal_families": len(encoded["family_size"]),
                "strata": len(encoded["group_offsets"]) - 1,
            }
        )
        boundary_p_upper = (
            1 + np.sum(permuted_boundary >= actual_boundary_coefficient)
        ) / (PERMUTATIONS + 1)
        boundary_p_two_sided = (
            1
            + np.sum(
                np.abs(permuted_boundary - np.mean(permuted_boundary))
                >= abs(
                    actual_boundary_coefficient - np.mean(permuted_boundary)
                )
            )
        ) / (PERMUTATIONS + 1)
        boundary_draw_tables.append(
            pd.DataFrame(
                {
                    "universe": universe_name,
                    "exposure": exposure_column,
                    "shuffle_stratum": stratum_kind,
                    "permutation": np.arange(1, PERMUTATIONS + 1),
                    "same_journal_coefficient": permuted_boundary,
                    "same_journal_gap_pp": 100 * permuted_boundary,
                }
            )
        )
        boundary_summary_rows.append(
            {
                "universe": universe_name,
                "exposure": exposure_column,
                "shuffle_stratum": stratum_kind,
                "permutations": PERMUTATIONS,
                "actual_same_journal_coefficient": actual_boundary_coefficient,
                "actual_same_journal_gap_pp": 100 * actual_boundary_coefficient,
                "permutation_mean": float(np.mean(permuted_boundary)),
                "permutation_sd": float(np.std(permuted_boundary, ddof=1)),
                "permutation_q025": float(
                    np.quantile(permuted_boundary, 0.025)
                ),
                "permutation_q975": float(
                    np.quantile(permuted_boundary, 0.975)
                ),
                "empirical_p_upper": boundary_p_upper,
                "empirical_p_two_sided": boundary_p_two_sided,
            }
        )
        print(
            universe_name,
            exposure_column,
            f"actual={actual_coefficient:.6f}",
            f"null_mean={np.mean(permuted):.6f}",
            f"p_upper={empirical_p_upper:.4f}",
            flush=True,
        )

draw_table = pd.concat(draw_tables, ignore_index=True)
summary_table = pd.DataFrame(summary_rows)
draw_table.to_csv(DRAW_OUTPUT_PATH, index=False)
summary_table.to_csv(SUMMARY_OUTPUT_PATH, index=False)
print(summary_table.to_string(index=False))

boundary_draw_table = pd.concat(boundary_draw_tables, ignore_index=True)
boundary_summary_table = pd.DataFrame(boundary_summary_rows)
boundary_draw_table.to_csv(BOUNDARY_DRAW_OUTPUT_PATH, index=False)
boundary_summary_table.to_csv(BOUNDARY_SUMMARY_OUTPUT_PATH, index=False)
print(boundary_summary_table.to_string(index=False))

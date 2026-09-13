#!/usr/bin/env Rscript

# Estimate pair-level journal-boundary models with direct proximity controls.

suppressPackageStartupMessages({
  library(arrow)
  library(data.table)
  library(fixest)
  library(splines)
})

setFixest_nthreads(8)

input_path <-
  "results/direct_outcome_gap/pair_level_boundary_pairs.parquet"
output_directory <- "results/direct_outcome_gap"

data <- as.data.table(read_parquet(input_path))
data[, later_publication_year := as.character(as.integer(format(later_date, "%Y")))]
data[, focal_work_id := as.character(focal_work_id)]
data[, focal_topic_id := as.character(focal_topic_id)]
data[, focal_text_cluster_id := as.character(focal_text_cluster_id)]
data[, log_date_distance := log1p(publication_date_distance_days)]


extract_interaction <- function(model, exposure_name) {
  coefficient_names <- names(coef(model))
  candidate_names <- c(
    paste0("same_journal:", exposure_name),
    paste0(exposure_name, ":same_journal")
  )
  coefficient_name <- intersect(candidate_names, coefficient_names)
  if (length(coefficient_name) != 1L) {
    stop(paste("Could not identify interaction for", exposure_name))
  }
  coefficient <- coef(model)[[coefficient_name]]
  standard_error <- se(model)[[coefficient_name]]
  data.table(
    coefficient = coefficient,
    standard_error = standard_error,
    same_journal_gap_change_pp_for_effj_doubling =
      100 * coefficient * log(2),
    standard_error_pp_for_effj_doubling =
      100 * standard_error * log(2),
    p_value = pvalue(model)[[coefficient_name]],
    observations = nobs(model)
  )
}


fit_one <- function(
  input_data,
  universe_name,
  exposure_name,
  specification,
  field_name = "pooled",
  exclude_field = NA_character_
) {
  subset_data <- input_data[universe == universe_name]
  if (field_name != "pooled") {
    subset_data <- subset_data[analytic_field == field_name]
  }
  if (!is.na(exclude_field)) {
    subset_data <- subset_data[analytic_field != exclude_field]
  }
  cluster_name <- if (exposure_name == "text_log_eff_j") {
    "focal_text_cluster_id"
  } else {
    "focal_topic_id"
  }

  baseline_formula <- as.formula(paste0(
    "tie_count ~ same_journal + same_journal:", exposure_name,
    " | focal_work_id + later_publication_year"
  ))
  controlled_formula <- as.formula(paste0(
    "tie_count ~ same_journal + same_journal:", exposure_name,
    " + ns(cosine_similarity, df = 4)",
    " + bibliographic_coupling_cosine + shared_topic_jaccard",
    " + author_overlap + institution_overlap + country_overlap",
    " + ns(log_date_distance, df = 3)",
    " | focal_work_id + later_publication_year"
  ))
  flexible_formula <- as.formula(paste0(
    "tie_count ~ same_journal + same_journal:", exposure_name,
    " + ns(cosine_similarity, df = 4)",
    " + same_journal:ns(cosine_similarity, df = 4)",
    " + bibliographic_coupling_cosine + shared_topic_jaccard",
    " + author_overlap + institution_overlap + country_overlap",
    " + ns(log_date_distance, df = 3)",
    " | focal_work_id + later_publication_year"
  ))
  model_formula <- switch(
    specification,
    baseline = baseline_formula,
    controlled = controlled_formula,
    flexible_similarity = flexible_formula,
    stop(paste("Unknown specification:", specification))
  )
  model <- feols(
    model_formula,
    data = subset_data,
    vcov = as.formula(paste0("~", cluster_name)),
    fixef.rm = "none",
    notes = FALSE
  )
  result <- extract_interaction(model, exposure_name)
  result[, `:=`(
    universe = universe_name,
    exposure = exposure_name,
    specification = specification,
    field = field_name,
    excluded_field = exclude_field,
    focal_families = uniqueN(subset_data$focal_work_id)
  )]
  setcolorder(
    result,
    c(
      "universe", "exposure", "specification", "field",
      "excluded_field", "coefficient", "standard_error",
      "same_journal_gap_change_pp_for_effj_doubling",
      "standard_error_pp_for_effj_doubling", "p_value",
      "observations", "focal_families"
    )
  )
  result
}


pooled_results <- list()
result_index <- 1L
for (universe_name in c("full", "scimago")) {
  for (exposure_name in c("openalex_log_eff_j", "text_log_eff_j")) {
    for (specification in c(
      "baseline", "controlled", "flexible_similarity"
    )) {
      pooled_results[[result_index]] <- fit_one(
        data,
        universe_name,
        exposure_name,
        specification
      )
      result_index <- result_index + 1L
    }
  }
}
pooled_table <- rbindlist(pooled_results, fill = TRUE)
fwrite(
  pooled_table,
  file.path(output_directory, "pair_level_boundary_pooled_results.csv")
)
print(pooled_table)

fields <- sort(unique(data[universe == "full", analytic_field]))
field_results <- list()
result_index <- 1L
for (exposure_name in c("openalex_log_eff_j", "text_log_eff_j")) {
  for (field_name in fields) {
    field_results[[result_index]] <- fit_one(
      data,
      "full",
      exposure_name,
      "flexible_similarity",
      field_name = field_name
    )
    result_index <- result_index + 1L
  }
}
field_table <- rbindlist(field_results, fill = TRUE)
fwrite(
  field_table,
  file.path(output_directory, "pair_level_boundary_field_results.csv")
)
print(field_table)

leave_one_out_results <- list()
for (field_index in seq_along(fields)) {
  leave_one_out_results[[field_index]] <- fit_one(
    data,
    "full",
    "openalex_log_eff_j",
    "flexible_similarity",
    exclude_field = fields[[field_index]]
  )
}
leave_one_out_table <- rbindlist(leave_one_out_results, fill = TRUE)
fwrite(
  leave_one_out_table,
  file.path(output_directory, "pair_level_boundary_leave_one_out.csv")
)
print(leave_one_out_table)

curve_data <- copy(data[universe == "full"])
curve_data[, similarity_bin := frank(
  cosine_similarity,
  ties.method = "average",
  na.last = "keep"
)]
curve_data[, similarity_bin := pmin(
  20L,
  pmax(1L, ceiling(20 * similarity_bin / .N))
)]
curve_data[, effj_group := fcase(
  openalex_log_eff_j <= quantile(openalex_log_eff_j, 1 / 3), "Lower EffJ third",
  openalex_log_eff_j >= quantile(openalex_log_eff_j, 2 / 3), "Higher EffJ third",
  default = "Middle EffJ third"
)]
curve_table <- curve_data[
  effj_group != "Middle EffJ third",
  .(
    mean_cosine_similarity = mean(cosine_similarity),
    citation_probability = mean(tie_count),
    pair_count = .N,
    realized_ties = sum(tie_count),
    mean_eff_j = mean(exp(openalex_log_eff_j))
  ),
  by = .(
    effj_group,
    similarity_bin,
    boundary = fifelse(same_journal == 1, "Same journal", "Cross journal")
  )
]
fwrite(
  curve_table,
  file.path(output_directory, "pair_level_boundary_similarity_curves.csv")
)

balance_table <- data[
  , .(
    pairs = .N,
    realized_ties = sum(tie_count),
    tie_probability = mean(tie_count),
    mean_cosine_similarity = mean(cosine_similarity),
    mean_bibliographic_coupling = mean(bibliographic_coupling_cosine),
    mean_shared_topic_jaccard = mean(shared_topic_jaccard),
    author_overlap_share = mean(author_overlap),
    institution_overlap_share = mean(institution_overlap),
    country_overlap_share = mean(country_overlap),
    mean_date_distance_days = mean(publication_date_distance_days)
  ),
  by = .(
    universe,
    boundary = fifelse(same_journal == 1, "Same journal", "Cross journal")
  )
]
fwrite(
  balance_table,
  file.path(output_directory, "pair_level_boundary_descriptives.csv")
)
print(balance_table)

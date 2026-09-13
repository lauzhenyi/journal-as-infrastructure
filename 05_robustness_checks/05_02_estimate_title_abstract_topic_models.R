#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(arrow)
  library(data.table)
  library(fixest)
})

setFixest_nthreads(8)

input_path <- "results/direct_outcome_gap/text_only_coordination_panel.parquet"
output_path <- "results/direct_outcome_gap/text_only_coordination_fe_results.csv"

data <- as.data.table(read_parquet(input_path))
data[, panel_id := as.character(panel_id)]
data[, text_cluster_id := as.character(text_cluster_id)]
data[, publication_year := as.character(publication_year)]
data[, log_possible_pairs := log(possible_pairs)]


fit_one <- function(data, universe_name, scope_name_value) {
  subset_data <- data[
    universe == universe_name & scope_name == scope_name_value
  ]
  model <- fepois(
    tie_count ~ is_cross_journal + is_cross_journal:log_eff_j |
      panel_id + text_cluster_id^pair_type + publication_year^pair_type,
    offset = ~log_possible_pairs,
    data = subset_data,
    vcov = ~text_cluster_id,
    fixef.rm = "singleton",
    notes = FALSE
  )
  coefficient_name <- "is_cross_journal:log_eff_j"
  if (!coefficient_name %in% names(coef(model))) {
    coefficient_name <- "log_eff_j:is_cross_journal"
  }
  coefficient <- coef(model)[[coefficient_name]]
  standard_error <- se(model)[[coefficient_name]]
  data.table(
    universe = universe_name,
    scope_name = scope_name_value,
    taxonomy = "text_only_hashing_kmeans_256",
    outcome = "cross_vs_within_temporally_eligible_tie_rate",
    percent_change_for_effj_doubling =
      100 * (exp(coefficient * log(2)) - 1),
    standard_error_log_rate_doubling = standard_error * log(2),
    p_value = pvalue(model)[[coefficient_name]],
    observations = nobs(model)
  )
}


results <- list()
result_index <- 1L
for (universe_name in c("full", "scimago")) {
  for (scope_name_value in sort(unique(data$scope_name))) {
    message(sprintf("Fitting %s | %s", universe_name, scope_name_value))
    results[[result_index]] <- fit_one(
      data, universe_name, scope_name_value
    )
    result_index <- result_index + 1L
  }
}

result_table <- rbindlist(results)
fwrite(result_table, output_path)
print(result_table)


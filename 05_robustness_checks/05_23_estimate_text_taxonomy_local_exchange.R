#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(arrow)
  library(data.table)
  library(fixest)
})

setFixest_nthreads(8)

input_path <-
  "results/direct_outcome_gap/text_taxonomy_local_exchange.parquet"
output_path <-
  "results/direct_outcome_gap/text_taxonomy_local_exchange_results.csv"

data <- as.data.table(read_parquet(input_path))
data[, author_id := as.character(author_id)]
data[, institution_id := as.character(institution_id)]
data[, text_cluster_id := as.character(text_cluster_id)]
data[, field_year_id := as.character(field_year_id)]
data[, log_possible_pairs := log(possible_pairs)]


fit_one <- function(data, universe_name, scope_name_value, pair_type_name) {
  subset_data <- data[
    universe == universe_name &
      scope_name == scope_name_value &
      pair_type == pair_type_name
  ]
  model <- fepois(
    tie_count ~ log_eff_j + log_cell_n + log_authors + oa_value |
      author_id + institution_id + text_cluster_id + field_year_id,
    data = subset_data,
    offset = ~log_possible_pairs,
    vcov = ~author_id,
    fixef.rm = "singleton",
    notes = FALSE
  )
  coefficient <- coef(model)[["log_eff_j"]]
  data.table(
    universe = universe_name,
    analytic_field = scope_name_value,
    exchange_boundary = pair_type_name,
    taxonomy = "text_only_hashing_kmeans_256",
    sample = "single_focal_paper",
    outcome = "temporally_eligible_citation_tie_rate",
    percent_change_per_eff_j_doubling =
      100 * (exp(coefficient * log(2)) - 1),
    standard_error_log_rate_doubling =
      se(model)[["log_eff_j"]] * log(2),
    p_value = pvalue(model)[["log_eff_j"]],
    observations = nobs(model)
  )
}


results <- list()
index <- 1L
for (universe_name in c("full", "scimago")) {
  for (pair_type_name in c("within", "cross")) {
    for (scope_name_value in sort(unique(data$scope_name))) {
      results[[index]] <- fit_one(
        data,
        universe_name,
        scope_name_value,
        pair_type_name
      )
      index <- index + 1L
    }
  }
}

result_table <- rbindlist(results)
fwrite(result_table, output_path)
print(result_table)

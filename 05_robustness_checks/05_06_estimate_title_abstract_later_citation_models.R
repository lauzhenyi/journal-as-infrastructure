#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(arrow)
  library(data.table)
  library(fixest)
})

setFixest_nthreads(8)
output_directory <- "results/cumulative_handoff"
family <- as.data.table(read_parquet(file.path(
  output_directory, "text_handoff_family_panel.parquet"
)))
subfield <- as.data.table(read_parquet(file.path(
  output_directory, "text_handoff_subfield_panel.parquet"
)))

family[, text_cluster_year_id := as.character(text_cluster_year_id)]
family[, corresponding_author_id := as.character(corresponding_author_id)]
family[, early_member_factor := as.factor(early_member_count)]
family[, log_late_members := log(late_member_count)]
family[, log_eligible_late_citers := log(eligible_late_citers)]
subfield[, panel_id := as.character(panel_id)]
subfield[, cluster_pair_id := as.character(cluster_pair_id)]
subfield[, year_pair_id := as.character(year_pair_id)]
subfield[, text_cluster_id := as.character(text_cluster_id)]


select_family_scope <- function(data, universe_name, scope_name) {
  if (startsWith(scope_name, "exclude_")) {
    excluded_field <- sub("^exclude_", "", scope_name)
    data[universe == universe_name & analytic_field != excluded_field]
  } else {
    data[
      universe == universe_name &
        (scope_name == "pooled" | analytic_field == scope_name)
    ]
  }
}


fit_family <- function(data, universe_name, scope_name) {
  subset_data <- select_family_scope(data, universe_name, scope_name)
  coordination_sd <- sd(subset_data$log_early_cross_rate)
  model <- fepois(
    late_citers_with_handoff ~ log_early_cross_rate +
      log_early_within_rate + log_early_opportunities +
      log_late_members + log_early_member_prior_citations +
      log_max_early_member_prior_citations + log_authors + oa_value |
      text_cluster_year_id + early_member_factor + corresponding_author_id,
    data = subset_data,
    offset = ~log_eligible_late_citers,
    vcov = ~corresponding_author_id,
    fixef.rm = "singleton",
    notes = FALSE
  )
  coefficient <- coef(model)[["log_early_cross_rate"]]
  data.table(
    scale = "focal_research_lineage",
    universe = universe_name,
    analytic_field = scope_name,
    taxonomy = "title_abstract_only_256_clusters",
    percent_change_per_one_sd =
      100 * (exp(coefficient * coordination_sd) - 1),
    standard_error = se(model)[["log_early_cross_rate"]],
    p_value = pvalue(model)[["log_early_cross_rate"]],
    observations = nobs(model)
  )
}


fit_subfield <- function(data, universe_name, scope_value) {
  subset_data <- data[
    universe == universe_name & scope_name == scope_value
  ]
  gap_sd <- sd(unique(subset_data[, .(panel_id, early_coordination_gap)])[
    , early_coordination_gap
  ])
  model <- fepois(
    late_citers_with_handoff ~ is_cross:early_coordination_gap +
      log_early_options_per_late_citer |
      panel_id + cluster_pair_id + year_pair_id,
    data = subset_data,
    offset = ~log_eligible_late_citers,
    vcov = ~text_cluster_id,
    fixef.rm = "singleton",
    notes = FALSE
  )
  term <- "early_coordination_gap:is_cross"
  if (!term %in% names(coef(model))) {
    term <- "is_cross:early_coordination_gap"
  }
  coefficient <- coef(model)[[term]]
  data.table(
    scale = "subfield_cross_boundary_handoff",
    universe = universe_name,
    analytic_field = scope_value,
    taxonomy = "title_abstract_only_256_clusters",
    percent_change_per_one_sd =
      100 * (exp(coefficient * gap_sd) - 1),
    standard_error = se(model)[[term]],
    p_value = pvalue(model)[[term]],
    observations = nobs(model)
  )
}


fields <- sort(unique(family$analytic_field))
scopes <- c("pooled", fields, paste0("exclude_", fields))
results <- list()
index <- 1L
for (universe_name in c("full", "scimago")) {
  for (scope_name in scopes) {
    results[[index]] <- fit_family(family, universe_name, scope_name)
    index <- index + 1L
    results[[index]] <- fit_subfield(subfield, universe_name, scope_name)
    index <- index + 1L
  }
}

result_table <- rbindlist(results)
fwrite(
  result_table,
  file.path(output_directory, "text_taxonomy_handoff_results.csv")
)
print(result_table)

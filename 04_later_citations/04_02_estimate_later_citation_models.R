#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(arrow)
  library(data.table)
  library(fixest)
})

setFixest_nthreads(8)

output_directory <- "results/cumulative_handoff"
family <- as.data.table(read_parquet(file.path(
  output_directory, "cumulative_handoff_family_panel.parquet"
)))
subfield <- as.data.table(read_parquet(file.path(
  output_directory, "cumulative_handoff_subfield_panel.parquet"
)))

family[, topic_year_id := as.character(topic_year_id)]
family[, corresponding_author_id := as.character(corresponding_author_id)]
family[, topic_id := as.character(topic_id)]
family[, field_year_id := as.character(field_year_id)]
family[, early_member_factor := as.factor(early_member_count)]
family[, log_late_members := log(late_member_count)]
family[, log_eligible_late_citers := log(eligible_late_citers)]

subfield[, topic_year_id := as.character(topic_year_id)]
subfield[, topic_pair_id := as.character(topic_pair_id)]
subfield[, field_year_pair_id := as.character(field_year_pair_id)]
subfield[, topic_id := as.character(topic_id)]


select_scope <- function(data, universe_name, scope_name) {
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
  subset_data <- select_scope(data, universe_name, scope_name)
  coordination_sd <- sd(subset_data$log_early_cross_rate)
  model <- fepois(
    late_citers_with_handoff ~ log_early_cross_rate + log_early_within_rate +
      log_early_opportunities + log_late_members +
      log_early_member_prior_citations +
      log_max_early_member_prior_citations + log_authors + oa_value |
      topic_year_id + early_member_factor + corresponding_author_id,
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
    outcome = "share_of_late_citers_handing_off_to_early_work",
    estimate_per_log_rate = coefficient,
    standard_error = se(model)[["log_early_cross_rate"]],
    percent_change_per_one_sd_early_cross_coordination =
      100 * (exp(coefficient * coordination_sd) - 1),
    p_value = pvalue(model)[["log_early_cross_rate"]],
    observations = nobs(model)
  )
}


fit_direct_family <- function(data, universe_name, scope_name) {
  subset_data <- select_scope(data, universe_name, scope_name)
  model <- fepois(
    late_citers_with_handoff ~ log_eff_j + log_early_opportunities +
      log_late_members + log_early_member_prior_citations +
      log_max_early_member_prior_citations + log_cell_n +
      log_authors + oa_value |
      topic_id + field_year_id + early_member_factor +
      corresponding_author_id,
    data = subset_data,
    offset = ~log_eligible_late_citers,
    vcov = ~topic_id,
    fixef.rm = "singleton",
    notes = FALSE
  )
  coefficient <- coef(model)[["log_eff_j"]]
  data.table(
    scale = "direct_focal_research_lineage",
    universe = universe_name,
    analytic_field = scope_name,
    outcome = "share_of_late_citers_handing_off_to_early_work",
    estimate_per_log_eff_j = coefficient,
    standard_error = se(model)[["log_eff_j"]],
    percent_change_per_eff_j_doubling =
      100 * (exp(coefficient * log(2)) - 1),
    p_value = pvalue(model)[["log_eff_j"]],
    observations = nobs(model)
  )
}


fit_subfield <- function(data, universe_name, scope_name) {
  subset_data <- select_scope(data, universe_name, scope_name)
  gap_sd <- sd(unique(subset_data[, .(topic_year_id, early_coordination_gap)])[
    , early_coordination_gap
  ])
  model <- fepois(
    late_citers_with_handoff ~ is_cross:early_coordination_gap +
      log_early_options_per_late_citer |
      topic_year_id + topic_pair_id + field_year_pair_id,
    data = subset_data,
    offset = ~log_eligible_late_citers,
    vcov = ~topic_id,
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
    analytic_field = scope_name,
    outcome = "relative_cross_journal_handoff_rate",
    estimate_per_log_gap = coefficient,
    standard_error = se(model)[[term]],
    percent_change_per_one_sd_early_coordination_gap =
      100 * (exp(coefficient * gap_sd) - 1),
    p_value = pvalue(model)[[term]],
    observations = nobs(model)
  )
}


fit_direct_subfield <- function(data, universe_name, scope_name) {
  subset_data <- select_scope(data, universe_name, scope_name)
  model <- fepois(
    late_citers_with_handoff ~ is_cross:log_eff_j +
      log_early_options_per_late_citer |
      topic_year_id + topic_pair_id + field_year_pair_id,
    data = subset_data,
    offset = ~log_eligible_late_citers,
    vcov = ~topic_id,
    fixef.rm = "singleton",
    notes = FALSE
  )
  term <- "log_eff_j:is_cross"
  if (!term %in% names(coef(model))) {
    term <- "is_cross:log_eff_j"
  }
  coefficient <- coef(model)[[term]]
  data.table(
    scale = "direct_subfield_handoff",
    universe = universe_name,
    analytic_field = scope_name,
    outcome = "relative_cross_journal_handoff_rate",
    estimate_per_log_eff_j = coefficient,
    standard_error = se(model)[[term]],
    percent_change_per_eff_j_doubling =
      100 * (exp(coefficient * log(2)) - 1),
    p_value = pvalue(model)[[term]],
    observations = nobs(model)
  )
}


fields <- sort(unique(family$analytic_field))
scopes <- c("pooled", fields, paste0("exclude_", fields))
results <- list()
result_index <- 1L

for (universe_name in c("full", "scimago")) {
  for (scope_name in scopes) {
    message(sprintf("Fitting family | %s | %s", universe_name, scope_name))
    results[[result_index]] <- fit_family(
      family, universe_name, scope_name
    )
    result_index <- result_index + 1L
    message(sprintf(
      "Fitting direct family | %s | %s", universe_name, scope_name
    ))
    results[[result_index]] <- fit_direct_family(
      family, universe_name, scope_name
    )
    result_index <- result_index + 1L
    message(sprintf("Fitting subfield | %s | %s", universe_name, scope_name))
    results[[result_index]] <- fit_subfield(
      subfield, universe_name, scope_name
    )
    result_index <- result_index + 1L
    message(sprintf(
      "Fitting direct subfield | %s | %s", universe_name, scope_name
    ))
    results[[result_index]] <- fit_direct_subfield(
      subfield, universe_name, scope_name
    )
    result_index <- result_index + 1L
  }
}

all_result_table <- rbindlist(results, fill = TRUE)
result_table <- all_result_table[
  scale != "direct_focal_research_lineage"
]
exclusion_audit <- all_result_table[
  scale == "direct_focal_research_lineage"
]
fwrite(
  result_table,
  file.path(output_directory, "cumulative_handoff_results.csv")
)
fwrite(
  exclusion_audit,
  file.path(output_directory, "cumulative_handoff_exclusion_audit.csv")
)
print(result_table)

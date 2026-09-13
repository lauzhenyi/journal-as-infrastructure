#!/usr/bin/env Rscript

# Estimate the joint EffJ -> early CJR -> later cross-journal uptake pathway.

suppressPackageStartupMessages({
  library(arrow)
  library(data.table)
  library(fixest)
})

setFixest_nthreads(8)

outcome_input_path <-
  "results/cumulative_handoff/cumulative_handoff_subfield_panel.parquet"
mediator_input_path <-
  "results/direct_outcome_gap/temporal_coordination_topic_year.parquet"
output_path <- "results/cumulative_handoff/joint_effj_cjr_handoff_results.csv"

panel <- as.data.table(read_parquet(outcome_input_path))
panel[, topic_id := as.character(topic_id)]
panel[, topic_year_id := as.character(topic_year_id)]
panel[, topic_pair_id := as.character(topic_pair_id)]
panel[, field_year_id := as.character(field_year_id)]
panel[, field_year_pair_id := as.character(field_year_pair_id)]

mediator_panel <- as.data.table(read_parquet(mediator_input_path))
mediator_panel[, panel_id := as.character(panel_id)]
mediator_panel[, topic_id := as.character(topic_id)]
mediator_panel[, field_year_id := as.character(field_year_id)]
mediator_panel[, log_possible_pairs := log(possible_pairs)]


select_scope <- function(data, universe_name, scope_name) {
  data[
    universe == universe_name &
      (scope_name == "pooled" | analytic_field == scope_name)
  ]
}


interaction_term <- function(model, exposure, boundary = "is_cross") {
  candidates <- c(
    paste0(boundary, ":", exposure),
    paste0(exposure, ":", boundary)
  )
  term <- intersect(candidates, names(coef(model)))
  if (length(term) != 1L) {
    stop(sprintf("Could not identify interaction for %s", exposure))
  }
  term
}


fit_path <- function(data, universe_name, scope_name) {
  outcome_data <- select_scope(data, universe_name, scope_name)
  handoff_keys <- unique(outcome_data[, .(
    universe,
    analytic_field,
    publication_year,
    topic_id
  )])
  mediator_data <- mediator_panel[
    handoff_keys,
    on = .(universe, analytic_field, publication_year, topic_id),
    nomatch = 0
  ]

  mediator_model <- fepois(
    tie_count ~ is_cross_journal:log_eff_j |
      panel_id + topic_id^pair_type + field_year_id^pair_type,
    data = mediator_data,
    offset = ~log_possible_pairs,
    vcov = ~topic_id,
    fixef.rm = "singleton",
    notes = FALSE
  )

  total_model <- fepois(
    late_citers_with_handoff ~ is_cross:log_eff_j +
      log_early_options_per_late_citer |
      topic_year_id + topic_pair_id + field_year_pair_id,
    data = outcome_data,
    offset = ~log_eligible_late_citers,
    vcov = ~topic_id,
    fixef.rm = "singleton",
    notes = FALSE
  )

  joint_model <- fepois(
    late_citers_with_handoff ~ is_cross:log_eff_j +
      is_cross:early_coordination_gap +
      log_early_options_per_late_citer |
      topic_year_id + topic_pair_id + field_year_pair_id,
    data = outcome_data,
    offset = ~log_eligible_late_citers,
    vcov = ~topic_id,
    fixef.rm = "singleton",
    notes = FALSE
  )

  mediator_effj_term <- interaction_term(
    mediator_model,
    "log_eff_j",
    "is_cross_journal"
  )
  a <- coef(mediator_model)[[mediator_effj_term]]
  se_a <- se(mediator_model)[[mediator_effj_term]]
  p_a <- pvalue(mediator_model)[[mediator_effj_term]]

  total_term <- interaction_term(total_model, "log_eff_j")
  total <- coef(total_model)[[total_term]]
  se_total <- se(total_model)[[total_term]]
  p_total <- pvalue(total_model)[[total_term]]

  direct_term <- interaction_term(joint_model, "log_eff_j")
  mediator_term <- interaction_term(joint_model, "early_coordination_gap")
  direct <- coef(joint_model)[[direct_term]]
  se_direct <- se(joint_model)[[direct_term]]
  p_direct <- pvalue(joint_model)[[direct_term]]
  b <- coef(joint_model)[[mediator_term]]
  se_b <- se(joint_model)[[mediator_term]]
  p_b <- pvalue(joint_model)[[mediator_term]]

  indirect <- a * b
  se_indirect_delta <- sqrt((b^2 * se_a^2) + (a^2 * se_b^2))
  z_indirect <- indirect / se_indirect_delta
  p_indirect_delta <- 2 * pnorm(abs(z_indirect), lower.tail = FALSE)
  gap_sd <- sd(unique(outcome_data[, .(
    topic_year_id, early_coordination_gap
  )])$early_coordination_gap)

  data.table(
    universe = universe_name,
    analytic_field = scope_name,
    mediator_observations = nobs(mediator_model),
    outcome_observations_total = nobs(total_model),
    outcome_observations_joint = nobs(joint_model),
    topics = uniqueN(outcome_data$topic_id),
    a_effj_to_early_log_cjr = a,
    a_standard_error = se_a,
    a_p_value = p_a,
    early_cjr_change_percent_per_effj_doubling =
      100 * (exp(a * log(2)) - 1),
    b_early_log_cjr_to_later_cross_boundary = b,
    b_standard_error = se_b,
    b_p_value = p_b,
    later_cross_boundary_change_percent_per_one_sd_early_cjr =
      100 * (exp(b * gap_sd) - 1),
    total_log_effect_per_log_effj = total,
    total_standard_error = se_total,
    total_p_value = p_total,
    total_change_percent_per_effj_doubling =
      100 * (exp(total * log(2)) - 1),
    direct_log_effect_per_log_effj = direct,
    direct_standard_error = se_direct,
    direct_p_value = p_direct,
    direct_change_percent_per_effj_doubling =
      100 * (exp(direct * log(2)) - 1),
    indirect_log_effect_per_log_effj = indirect,
    indirect_standard_error_delta = se_indirect_delta,
    indirect_p_value_delta = p_indirect_delta,
    indirect_change_percent_per_effj_doubling =
      100 * (exp(indirect * log(2)) - 1),
    implied_total_change_percent_per_effj_doubling =
      100 * (exp((direct + indirect) * log(2)) - 1)
  )
}


fields <- sort(unique(panel$analytic_field))
results <- list()
result_index <- 1L
for (universe_name in c("full", "scimago")) {
  for (scope_name in c("pooled", fields)) {
    message(sprintf("Fitting joint path | %s | %s", universe_name, scope_name))
    results[[result_index]] <- fit_path(panel, universe_name, scope_name)
    result_index <- result_index + 1L
  }
}

result_table <- rbindlist(results, fill = TRUE)
fwrite(result_table, output_path)
print(result_table)

-- Prepared database schema snapshot.
-- Generated read-only from /private/tmp/journal_structure_six.duckdb on 2026-08-30.

-- six_base
CREATE TABLE six_base(work_id VARCHAR, publication_date DATE, publication_year BIGINT, analytic_field VARCHAR, topic_id VARCHAR, topic_name VARCHAR, source_id VARCHAR, source_name VARCHAR, "language" VARCHAR, log_authors DOUBLE, oa_value DOUBLE, sjr_matched BOOLEAN, citations_2y HUGEINT, citations_3y HUGEINT, citations_5y HUGEINT, first_citation_year BIGINT);;

-- paper_universes
CREATE TABLE paper_universes(universe VARCHAR, work_id VARCHAR, publication_date DATE, publication_year BIGINT, analytic_field VARCHAR, topic_id VARCHAR, topic_name VARCHAR, source_id VARCHAR, source_name VARCHAR, "language" VARCHAR, log_authors DOUBLE, oa_value DOUBLE, sjr_matched BOOLEAN, citations_2y HUGEINT, citations_3y HUGEINT, citations_5y HUGEINT, first_citation_year BIGINT);;

-- analysis_articles
CREATE TABLE analysis_articles(universe VARCHAR, work_id VARCHAR, publication_date DATE, publication_year BIGINT, analytic_field VARCHAR, topic_id VARCHAR, topic_name VARCHAR, source_id VARCHAR, source_name VARCHAR, "language" VARCHAR, log_authors DOUBLE, oa_value DOUBLE, sjr_matched BOOLEAN, citations_2y HUGEINT, citations_3y HUGEINT, citations_5y HUGEINT, first_citation_year BIGINT, log_citations_2y DOUBLE, log_citations_3y DOUBLE, log_citations_5y DOUBLE, citation_z_3y DOUBLE, cited_in_publication_year DOUBLE, cited_within_2y DOUBLE, cited_within_3y DOUBLE, first_citation_delay_capped_3y BIGINT, citation_abs_dev_3y DOUBLE, cell_n HUGEINT, journal_count BIGINT, eff_j DOUBLE, log_eff_j DOUBLE, corresponding_author_id VARCHAR, corresponding_institution_id VARCHAR, n_corresponding BIGINT, n_corresponding_institutions BIGINT, field_year_id VARCHAR);;

-- corresponding_author
CREATE TABLE corresponding_author(work_id VARCHAR, author_id VARCHAR, n_corresponding BIGINT);;

-- corresponding_institution
CREATE TABLE corresponding_institution(work_id VARCHAR, author_id VARCHAR, institution_id VARCHAR, n_corresponding_institutions BIGINT);;

-- eligible_follow_on_works_six
CREATE TABLE eligible_follow_on_works_six(work_id VARCHAR, publication_year BIGINT, publication_date DATE, source_id VARCHAR, sjr_matched BOOLEAN);;

-- journal_topic_year_counts_six
CREATE TABLE journal_topic_year_counts_six(universe VARCHAR, analytic_field VARCHAR, topic_id VARCHAR, publication_year BIGINT, source_id VARCHAR, journal_papers BIGINT, topic_year_papers HUGEINT, journal_share DOUBLE);;

-- journal_exposure
CREATE TABLE journal_exposure(universe VARCHAR, analytic_field VARCHAR, publication_year BIGINT, topic_id VARCHAR, cell_n HUGEINT, journal_count BIGINT, eff_j DOUBLE, log_eff_j DOUBLE);;

-- attention_member_six
CREATE TABLE attention_member_six(universe VARCHAR, focal_work_id VARCHAR, horizon INTEGER, citing_work_id VARCHAR, citing_topic_id VARCHAR, citing_field_id BIGINT, citing_domain_id VARCHAR, citing_institution_id VARCHAR, citing_country_code VARCHAR);;

-- family_citer_ids_six
CREATE TABLE family_citer_ids_six(work_id VARCHAR);;

-- citer_intellectual_metadata_six
CREATE TABLE citer_intellectual_metadata_six(work_id VARCHAR, citing_topic_id VARCHAR, citing_field_id BIGINT, citing_domain_id VARCHAR);;

-- conversation_focal_six
CREATE TABLE conversation_focal_six(focal_work_id VARCHAR, focal_year BIGINT, focal_date DATE, analytic_field VARCHAR, topic_id VARCHAR, focal_source_id VARCHAR, focal_sjr_matched BOOLEAN, log_authors DOUBLE, oa_value DOUBLE, corresponding_author_id VARCHAR, corresponding_institution_id VARCHAR);;

-- conversation_family_long_six
CREATE TABLE conversation_family_long_six(universe VARCHAR, focal_work_id VARCHAR, focal_year BIGINT, focal_date DATE, citing_work_id VARCHAR, citing_year BIGINT, citing_date DATE, citing_source_id VARCHAR);;

-- conversation_pair_long_six
CREATE TABLE conversation_pair_long_six(universe VARCHAR, focal_work_id VARCHAR, later_work_id VARCHAR, earlier_work_id VARCHAR, pair_year BIGINT, pair_date DATE, later_source_id VARCHAR, earlier_source_id VARCHAR, pair_sjr_matched BOOLEAN);;

-- conversation_family_horizon_six
CREATE TABLE conversation_family_horizon_six(universe VARCHAR, focal_work_id VARCHAR, focal_year BIGINT, focal_date DATE, citing_work_id VARCHAR, citing_year BIGINT, citing_date DATE, citing_source_id VARCHAR, horizon INTEGER);;

-- conversation_pair_horizon_six
CREATE TABLE conversation_pair_horizon_six(universe VARCHAR, focal_work_id VARCHAR, later_work_id VARCHAR, earlier_work_id VARCHAR, pair_year BIGINT, pair_date DATE, later_source_id VARCHAR, earlier_source_id VARCHAR, pair_sjr_matched BOOLEAN, focal_year BIGINT, horizon INTEGER);;

-- conversation_outcomes_six
CREATE TABLE conversation_outcomes_six(universe VARCHAR, focal_work_id VARCHAR, analytic_field VARCHAR, focal_year BIGINT, topic_id VARCHAR, log_authors DOUBLE, oa_value DOUBLE, cell_n HUGEINT, log_eff_j DOUBLE, corresponding_author_id VARCHAR, corresponding_institution_id VARCHAR, field_year_id VARCHAR, horizon INTEGER, n_citers HUGEINT, n_citer_journals BIGINT, citer_eff_j DOUBLE, same_journal_possible_pairs DOUBLE, possible_pairs DOUBLE, cross_journal_possible_pairs DOUBLE, internal_ties BIGINT, cross_journal_ties HUGEINT, within_journal_ties HUGEINT, involved_citers BIGINT, any_internal_tie DOUBLE, internal_tie_density_pp DOUBLE, isolated_citer_share DOUBLE, cross_journal_tie_density_pp DOUBLE, within_journal_tie_density_pp DOUBLE, first_internal_tie_year BIGINT, first_internal_tie_date DATE, first_citation_year BIGINT, first_citation_date DATE, jan1_date_share DOUBLE);;

-- citer_corresponding_institution_six
CREATE TABLE citer_corresponding_institution_six(work_id VARCHAR, author_id VARCHAR, institution_id VARCHAR, institution_country_code VARCHAR);;

-- researcher_attention_cohort_six
CREATE TABLE researcher_attention_cohort_six(universe VARCHAR, author_id VARCHAR, institution_id VARCHAR, analytic_field VARCHAR, cohort_year BIGINT, focal_work_id VARCHAR, topic_id VARCHAR, citations_3y HUGEINT, citation_z_3y DOUBLE, log_eff_j DOUBLE, cell_n HUGEINT, log_authors DOUBLE, oa_value DOUBLE, field_year_id VARCHAR);;

-- researcher_attention_panel_six
CREATE TABLE researcher_attention_panel_six(universe VARCHAR, author_id VARCHAR, institution_id VARCHAR, analytic_field VARCHAR, cohort_year BIGINT, field_year_id VARCHAR, focal_papers BIGINT, mean_log_eff_j DOUBLE, mean_log_cell_n DOUBLE, mean_log_authors DOUBLE, oa_share DOUBLE, total_citations_3y HUGEINT, mean_citation_z_3y DOUBLE, paper_summed_citers HUGEINT, top_paper_attention_share DOUBLE, portfolio_attention_hhi DOUBLE, unique_citing_works BIGINT, unique_citing_authors BIGINT, distinct_attention_fields BIGINT, external_attention_share DOUBLE, external_institution_attention_share DOUBLE, distinct_attention_topics BIGINT, effective_attention_topics DOUBLE, distinct_attention_institutions BIGINT, effective_attention_institutions DOUBLE, distinct_attention_countries BIGINT, effective_attention_countries DOUBLE);;

-- journal_exposure_alternatives_six
CREATE TABLE journal_exposure_alternatives_six(universe VARCHAR, analytic_field VARCHAR, publication_year BIGINT, topic_id VARCHAR, journal_count BIGINT, log_journal_count DOUBLE, journal_entropy DOUBLE, entropy_effective_journals DOUBLE);;

-- robust_topic_exposure_six
CREATE TABLE robust_topic_exposure_six(universe VARCHAR, analytic_field VARCHAR, publication_year BIGINT, topic_id VARCHAR, cell_n HUGEINT, journal_count BIGINT, eff_j DOUBLE, log_eff_j DOUBLE, log_journal_count DOUBLE, journal_entropy DOUBLE, log_entropy_effective_journals DOUBLE, hhi_recomputed DOUBLE, top1_journal_share DOUBLE, top5_journal_share DOUBLE, top10_journal_share DOUBLE, lag1_log_eff_j DOUBLE, prior3_mean_log_eff_j DOUBLE, prior3_years_available BIGINT);;

-- scimago_annual_sjr_source_six
CREATE TABLE scimago_annual_sjr_source_six(source_id VARCHAR, "year" BIGINT, scimago_source_id BIGINT, title VARCHAR, sjr DOUBLE, log_sjr DOUBLE, best_quartile VARCHAR, candidate_count BIGINT);;

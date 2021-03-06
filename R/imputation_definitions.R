
mice_imputation_hyperparameters <- list(

  pmm = list(donors = (0:2)*3 + 1, ridge = c(1e-03, 1e-04, 1e-05, 1e-06, 1e-07, 1e-08), matchtype = 0:2),
  norm.predict = list(),
  norm = list(),
  rf = list(ntree = 0:10 * 2 + 1),
  midastouch = list(ridge = c(1e-03, 1e-04, 1e-05, 1e-06, 1e-07, 1e-08), output = FALSE)
)

mice_hyperparameter_grids <- lapply(mice_imputation_hyperparameters, expand.grid)

deterministic_imputation_hyperparameters <- list(
  knnImputation = list(k = 1:20),
  bpca = list(nPcs = 2:30, maxSteps = 1:10*20)
)

other_hyperparameter_grids <- lapply(deterministic_imputation_hyperparameters, expand.grid)

single_value_imputation_hyperparameter_grids <- list(
  missingness_indicators = "missingness_indicators",
  max_imp = "max_imp",
  min_imp = "min_imp",
  mean_imp = "mean_imp",
  median_imp = "median_imp",
  zero_imp = "zero_imp",
  outlier_imp = "outlier_imp"
) %>% lapply(expand.grid)

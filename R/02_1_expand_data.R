
## Setup

library(magrittr)

set.seed(10)

source("R/preprocessing.R")

merged_data <- read.csv("merged_data.csv", as.is = TRUE)

source("R/feature_definitions.R")
source("R/recursive_application.R")

## Name data rows by strings identifying variants
form_variant_ids <- function(data) {

  id_cols <- c("X.Chrom", "Pos", "Ref", "Alt", "FeatureID")

  apply(
    data[, id_cols],
    MARGIN = 1,
    function(x) paste0(x, collapse = ":")
  )

}
rownames(merged_data) <- form_variant_ids(merged_data)

## Drop duplicates
merged_data_duplicates <- duplicated(merged_data[, c(numeric_features, categorical_features)])
sum(merged_data_duplicates)
merged_data <- merged_data[!merged_data_duplicates, ]

## Drop VUSes

vus <- merged_data$CLNSIG == "Uncertain_significance"
sum(vus)
merged_data <- merged_data[!vus, ]

## Data split
data_split <- split_train_test(merged_data, 0.7)

training_set <- data_split$training_set
test_set <- data_split$test_set

write.csv(file = "training_data.csv", x = training_set, row.names = FALSE)
write.csv(file = "test_data.csv", x = test_set, row.names = FALSE)

## Process variables

### Coding response

# The response variable (i.e. outcome variable) is processed into 0 (negative) or 1 (positive).
positive_classes <- c("Likely_pathogenic", "Pathogenic", "Pathogenic,_drug_response", "Pathogenic/Likely_pathogenic,_drug_response")
negative_classes <- c("Benign", "Likely_benign")

training_outcome <- compute_numeric_labels(training_set$CLNSIG, positive_classes, negative_classes)
names(training_outcome) <- row.names(training_set)
table(training_outcome)

test_outcome <- compute_numeric_labels(test_set$CLNSIG, positive_classes, negative_classes)
names(test_outcome) <- row.names(test_set)
table(test_outcome)

### Using a priori information to impute by constants

# Some variables have missing values that can be imputed with sensible default values using *a priori* information. For example, `motifEHIPos` is a variable that indicates whether the variant is highly informative to an overlapping motif. It is set to `NA` when there are no overlapping motifs. We can decide to impute the variable with `FALSE`, which is equivalent to defining that a variant is never highly informative to the inexistent motif. The information provided by the `NA` should be encoded in a different variable, which indicates whether the variant overlaps any motif. This actually exists as the variable `motifECount`, which contains the count of overlapping motifs, and `NA` when one does not exist. Again, it makes sense to impute this variable with `0`.

for (col in enumerate(default_imputations)) {
  miss_ind <- is.na(training_set[, col$name])
  training_set[miss_ind, col$name] <- rep(col$value, sum(miss_ind))
}
for (col in enumerate(default_imputations)) {
  miss_ind <- is.na(test_set[, col$name])
  test_set[miss_ind, col$name] <- rep(col$value, sum(miss_ind))
}

### Dummy variables

# Categorical variables are processed into sets of dummy variables. Note that here each category is represented by a dummy variable. An extra category could be represented using these variables by leaving each value for an observation as `0`; this is one strategy for handling missing values in categorical variables. However, missing values are left as missing values at this point so that predictive mean matching can be also experimented on.

training_dummy_categoricals <- dummify_categoricals(training_set[, categorical_features, drop = FALSE])
head(training_dummy_categoricals)

test_dummy_categoricals <- dummify_categoricals(test_set[, categorical_features, drop = FALSE])

# If some dummy variables are present on the test set but not on the training set, the classifier cannot learn to use them and thus should just be removed. If some dummy variables are present on the training set but not on the test set, the classifier may still benefit from the additional training information, and a constant zero variable should be created on the test set to indicate lack of belonging to that class.

# Since the latter scenario does not apply in our case, the implementation beyond checking for it is skipped.
training_dummy_names <- training_dummy_categoricals %>% colnames
test_dummy_names <- test_dummy_categoricals %>% colnames

if (!setequal(training_dummy_names, test_dummy_names)) {

  not_in_test_set <- setdiff(training_dummy_names, test_dummy_names)
  not_in_training_set <- setdiff(test_dummy_names, training_dummy_names)

  if (length(not_in_test_set) > 0) {
    not_in_test_set %>% paste0(collapse = ", ") %>% paste0(" not in the test set") %>% print
  }

  if (length(not_in_training_set) > 0) {
     not_in_training_set %>% paste0(collapse = ", ") %>% paste0(" not in the training set; removing") %>% print
     test_dummy_categoricals[, not_in_training_set] <- NULL
  }
}

# Next, the new dummy variables are bound to the `data.frame`. We keep also the original categorical variables, since they are easier to use for certain statistics computations.
training_set <- cbind(
  training_set,
  training_dummy_categoricals
)

test_set <- cbind(
  test_set,
  test_dummy_categoricals
)

## Class distribution per consequence

# Next, check whether all consequences have both positive and negative examples.
table_with_margin <- function(...) {
  tabl <- table(...)
  tabl %<>% cbind(ALL_ = rowSums(tabl))
  tabl %<>% rbind(ALL_ = colSums(tabl))
  return(tabl)
}
table_with_margin(training_set$Consequence.x, training_set$CLNSIG, useNA = "always") %>% as.data.frame
table_with_margin(training_set$Consequence.x, training_outcome, useNA = "always") %>% as.data.frame
# There is significant class imbalance seen when conditioning on the outcome. One might consider e.g. removing all stop-gain variants in the test set to avoid biasing the result. Since the training / test split was random, the distributions should be similar in the test set, and thus any stop-gain variants will likely also all be pathogenic in the test set. The model will then might learn to guess correctly looking only at the consequence, something that could also be programmed deterministically and thus is not interesting in a machine-learning perspective.

# Thus we remove variants from categories with very few examples (< 5 %) in either positive or negative category.
class_distribution <- table_with_margin(training_set$Consequence.x, training_outcome, useNA = "always") %>% as.data.frame
prop_pathg <- class_distribution[,"1"]/(class_distribution[,"0"] + class_distribution[,"1"])
unbalanced_conseqs <- class_distribution[(prop_pathg < 0.05 | prop_pathg > 0.95) & !is.na(prop_pathg), ]
tr_variants_w_unbalanced_class <- training_set$Consequence.x %in% rownames(unbalanced_conseqs)
training_set <- training_set[!tr_variants_w_unbalanced_class, ]
training_outcome <- training_outcome[!tr_variants_w_unbalanced_class]

te_variants_w_unbalanced_class <- test_set$Consequence.x %in% rownames(unbalanced_conseqs)
test_set <- test_set[!te_variants_w_unbalanced_class, ]
test_outcome <- test_outcome[!te_variants_w_unbalanced_class]
nrow(training_set)
nrow(test_set)

# Finally, write out the processed data CSV file.
write.csv(training_set, "preprocessed_training_data.csv", row.names = TRUE)
write.csv(test_set, "preprocessed_test_data.csv", row.names = TRUE)
write.csv(training_outcome, "training_outcomes.csv", row.names = TRUE)
write.csv(test_outcome, "test_outcomes.csv", row.names = TRUE)

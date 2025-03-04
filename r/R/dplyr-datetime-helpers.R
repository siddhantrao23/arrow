# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.

check_time_locale <- function(locale = Sys.getlocale("LC_TIME")) {
  if (tolower(Sys.info()[["sysname"]]) == "windows" && locale != "C") {
    # MingW C++ std::locale only supports "C" and "POSIX"
    stop(paste0(
      "On Windows, time locales other than 'C' are not supported in Arrow. ",
      "Consider setting `Sys.setlocale('LC_TIME', 'C')`"
    ))
  }
  locale
}

.helpers_function_map <- list(
  "lubridate::dminutes" = list(60, "s"),
  "lubridate::dhours" = list(3600, "s"),
  "lubridate::ddays" = list(86400, "s"),
  "lubridate::dweeks" = list(604800, "s"),
  "lubridate::dmonths" = list(2629800, "s"),
  "lubridate::dyears" = list(31557600, "s"),
  "lubridate::dseconds" = list(1, "s"),
  "lubridate::dmilliseconds" = list(1, "ms"),
  "lubridate::dmicroseconds" = list(1, "us"),
  "lubridate::dnanoseconds" = list(1, "ns")
)
make_duration <- function(x, unit) {
  # TODO(ARROW-15862): remove first cast to int64
  x <- build_expr("cast", x, options = cast_options(to_type = int64()))
  x$cast(duration(unit))
}

binding_format_datetime <- function(x, format = "", tz = "", usetz = FALSE) {
  if (usetz) {
    format <- paste(format, "%Z")
  }

  if (call_binding("is.POSIXct", x)) {
    # Make sure the timezone is reflected
    if (tz == "" && x$type()$timezone() != "") {
      tz <- x$type()$timezone()
    } else if (tz == "") {
      tz <- Sys.timezone()
    }
    x <- build_expr("cast", x, options = cast_options(to_type = timestamp(x$type()$unit(), tz)))
  }
  opts <- list(format = format, locale = Sys.getlocale("LC_TIME"))
  build_expr("strftime", x, options = opts)
}

# this is a helper function used for creating a difftime / duration objects from
# several of the accepted pieces (second, minute, hour, day, week)
duration_from_chunks <- function(chunks) {
  accepted_chunks <- c("second", "minute", "hour", "day", "week")
  matched_chunks <- accepted_chunks[pmatch(names(chunks), accepted_chunks, duplicates.ok = TRUE)]

  if (any(is.na(matched_chunks))) {
    abort(
      paste0(
        "named `difftime` units other than: ",
        oxford_paste(accepted_chunks, quote_symbol = "`"),
        " not supported in Arrow. \nInvalid `difftime` parts: ",
        oxford_paste(names(chunks[is.na(matched_chunks)]), quote_symbol = "`")
      )
    )
  }

  matched_chunks <- matched_chunks[!is.na(matched_chunks)]

  chunks <- chunks[matched_chunks]
  chunk_duration <- c(
    "second" = 1L,
    "minute" = 60L,
    "hour" = 3600L,
    "day" = 86400L,
    "week" = 604800L
  )

  # transform the duration of each chunk in seconds and add everything together
  duration <- 0
  for (chunk in names(chunks)) {
    duration <- duration + chunks[[chunk]] * chunk_duration[[chunk]]
  }
  duration
}


binding_as_date <- function(x,
                            format = NULL,
                            tryFormats = "%Y-%m-%d",
                            origin = "1970-01-01") {
  if (call_binding("is.Date", x)) {
    return(x)

    # cast from character
  } else if (call_binding("is.character", x)) {
    x <- binding_as_date_character(x, format, tryFormats)

    # cast from numeric
  } else if (call_binding("is.numeric", x)) {
    x <- binding_as_date_numeric(x, origin)
  }

  build_expr("cast", x, options = cast_options(to_type = date32()))
}

binding_as_date_character <- function(x,
                                      format = NULL,
                                      tryFormats = "%Y-%m-%d") {
  format <- format %||% tryFormats[[1]]
  # unit = 0L is the identifier for seconds in valid_time32_units
  build_expr("strptime", x, options = list(format = format, unit = 0L))
}

binding_as_date_numeric <- function(x, origin = "1970-01-01") {

  # Arrow does not support direct casting from double to date32(), but for
  # integer-like values we can go via int32()
  # TODO: revisit after ARROW-15798
  if (!call_binding("is.integer", x)) {
    x <- build_expr("cast", x, options = cast_options(to_type = int32()))
  }

  if (origin != "1970-01-01") {
    delta_in_sec <- call_binding("difftime", origin, "1970-01-01")
    # TODO: revisit after ARROW-15862
    # (casting from int32 -> duration or double -> duration)
    delta_in_days <- (delta_in_sec$cast(int64()) / 86400L)$cast(int32())
    x <- build_expr("+", x, delta_in_days)
  }

  x
}

#' Build formats from multiple orders
#'
#' This function is a vectorised version of `build_format_from_order()`. In
#' addition to `build_format_from_order()`, it also checks if the supplied
#' orders are currently supported.
#'
#' @inheritParams process_data_for_parsing
#'
#' @return a vector of unique formats
#'
#' @noRd
build_formats <- function(orders) {
  # only keep the letters and the underscore as separator -> allow the users to
  # pass strptime-like formats (with "%"). We process the data -> we need to
  # process the `orders` (even if supplied in the desired format)
  # Processing is needed (instead of passing
  # formats as-is) due to the processing of the character vector in parse_date_time()
  orders <- gsub("[^A-Za-z]", "", orders)
  orders <- gsub("Y", "y", orders)

  # we separate "ym', "my", and "yq" from the rest of the `orders` vector and
  # transform them. `ym` and `yq` -> `ymd` & `my` -> `myd`
  # this is needed for 2 reasons:
  # 1. strptime does not parse "2022-05" -> we add "-01", thus changing the format,
  # 2. for equivalence to lubridate, which parses `ym` to the first day of the month
  short_orders <- c("ym", "my")

  if (any(orders %in% short_orders)) {
    orders1 <- setdiff(orders, short_orders)
    orders2 <- intersect(orders, short_orders)
    orders2 <- paste0(orders2, "d")
    orders <- unique(c(orders2, orders1))
  }

  if (any(orders == "yq")) {
    orders1 <- setdiff(orders, "yq")
    orders2 <- "ymd"
    orders <- unique(c(orders1, orders2))
  }

  if (any(orders == "qy")) {
    orders1 <- setdiff(orders, "qy")
    orders2 <- "ymd"
    orders <- unique(c(orders1, orders2))
  }

  ymd_orders <- c("ymd", "ydm", "mdy", "myd", "dmy", "dym")
  ymd_hms_orders <- c(
    "ymd_HMS", "ymd_HM", "ymd_H", "dmy_HMS", "dmy_HM", "dmy_H", "mdy_HMS",
    "mdy_HM", "mdy_H", "ydm_HMS", "ydm_HM", "ydm_H"
  )
  # support "%I" hour formats
  ymd_ims_orders <- gsub("H", "I", ymd_hms_orders)

  supported_orders <- c(
    ymd_orders,
    ymd_hms_orders,
    gsub("_", " ", ymd_hms_orders), # allow "_", " " and "" as order separators
    gsub("_", "", ymd_hms_orders),
    ymd_ims_orders,
    gsub("_", " ", ymd_ims_orders), # allow "_", " " and "" as order separators
    gsub("_", "", ymd_ims_orders)
  )

  unsupported_passed_orders <- setdiff(orders, supported_orders)
  supported_passed_orders <- intersect(orders, supported_orders)

  # error only if there isn't at least one valid order we can try
  if (length(supported_passed_orders) == 0) {
    arrow_not_supported(
      paste0(
        oxford_paste(
          unsupported_passed_orders
        ),
        " `orders`"
      )
    )
  }

  formats_list <- map(orders, build_format_from_order)
  formats <- purrr::flatten_chr(formats_list)
  unique(formats)
}

#' Build formats from a single order
#'
#' @param order a single string date-time format, such as `"ymd"` or `"ymd_hms"`
#'
#' @return a vector of all possible formats derived from the input
#' order
#'
#' @noRd
build_format_from_order <- function(order) {
  char_list <- list(
    "y" = c("%y", "%Y"),
    "m" = c("%m", "%B", "%b"),
    "d" = "%d",
    "H" = "%H",
    "M" = "%M",
    "S" = "%S",
    "I" = "%I"
  )

  split_order <- strsplit(order, split = "")[[1]]

  outcome <- expand.grid(char_list[split_order])
  # we combine formats with and without the "-" separator, we will later
  # coalesce through all of them (benchmarking indicated this is a more
  # computationally efficient approach rather than figuring out if a string has
  # separators or not and applying only )
  # during parsing if the string to be parsed does not contain a separator
  formats_with_sep <- do.call(paste, c(outcome, sep = "-"))
  formats_without_sep <- do.call(paste, c(outcome, sep = ""))
  c(formats_with_sep, formats_without_sep)
}

#' Process data in preparation for parsing
#'
#' `process_data_for_parsing()` takes a data column and a vector of `orders` and
#' prepares several versions of the input data:
#'   * `processed_x` is a version of `x` where all separators were replaced with
#'  `"-"` and multiple separators were collapsed into a single one. This element
#'  is only set to an empty list when the `orders` argument indicate we're only
#'  interested in parsing the augmented version of `x`.
#'  * each of the other 3 elements augment `x` in some way
#'    * `augmented_x_ym` - builds the `ym` and `my` formats by adding `"01"`
#'    (to indicate the first day of the month)
#'    * `augmented_x_yq` - transforms the `yq` format to `ymd`, by deriving the
#'    first month of the quarter and adding `"01"` to indicate the first day
#'    * `augmented_x_qy` - transforms the `qy` format to `ymd` in a similar
#'    manner to `"yq"`
#'
#' @param x an Expression corresponding to a character or numeric vector of
#' dates to be parsed.
#' @param orders a character vector of date-time formats.
#'
#' @return a list made up of 4 lists, each a different version of x:
#'  * `processed_x`
#'  * `augmented_x_ym`
#'  * `augmented_x_yq`
#'  * `augmented_x_qy`
#' @noRd
process_data_for_parsing <- function(x, orders) {
  processed_x <- x$cast(string())

  # make all separators (non-letters and non-numbers) into "-"
  processed_x <- call_binding("gsub", "[^A-Za-z0-9]", "-", processed_x)
  # collapse multiple separators into a single one
  processed_x <- call_binding("gsub", "-{2,}", "-", processed_x)

  # we need to transform `x` when orders are `ym`, `my`, and `yq`
  # for `ym` and `my` orders we add a day ("01")
  # TODO: revisit after ARROW-16627
  augmented_x_ym <- NULL
  if (any(orders %in% c("ym", "my", "Ym", "mY"))) {
    # add day as "-01" if there is a "-" separator and as "01" if not
    augmented_x_ym <- call_binding(
      "if_else",
      call_binding("grepl", "-", processed_x),
      call_binding("paste0", processed_x, "-01"),
      call_binding("paste0", processed_x, "01")
    )
  }

  # for `yq` we need to transform the quarter into the start month (lubridate
  # behaviour) and then add 01 to parse to the first day of the quarter
  augmented_x_yq <- NULL
  if (any(orders %in% c("yq", "Yq"))) {
    # extract everything that comes after the `-` separator, i.e. the quarter
    # (e.g. 4 from 2022-4)
    quarter_x <- call_binding("gsub", "^.*?-", "", processed_x)
    # we should probably error if quarter is not in 1:4
    # extract everything that comes before the `-`, i.e. the year (e.g. 2002
    # in 2002-4)
    year_x <- call_binding("gsub", "-.*$", "", processed_x)
    quarter_x <- quarter_x$cast(int32())
    month_x <- (quarter_x - 1) * 3 + 1
    augmented_x_yq <- call_binding("paste0", year_x, "-", month_x, "-01")
  }

  # same as for `yq`, we need to derive the month from the quarter and add a
  # "01" to give us the first day of the month
  augmented_x_qy <- NULL
  if (any(orders %in% c("qy", "qY"))) {
    quarter_x <- call_binding("gsub", "-.*$", "", processed_x)
    quarter_x <- quarter_x$cast(int32())
    year_x <- call_binding("gsub", "^.*?-", "", processed_x)
    # year might be missing the final 0s when extracted from a float, hence the
    # need to pad
    year_x <- call_binding("str_pad", year_x, width = 4, side = "right", pad = "0")
    month_x <- (quarter_x - 1) * 3 + 1
    augmented_x_qy <- call_binding("paste0", year_x, "-", month_x, "-01")
  }

  list(
    "augmented_x_ym" = augmented_x_ym,
    "augmented_x_yq" = augmented_x_yq,
    "augmented_x_qy" = augmented_x_qy,
    "processed_x" = processed_x
  )
}


#' Attempt parsing
#'
#' This function does several things:
#'   * builds all possible `formats` from the supplied `orders`
#'   * processes the data with `process_data_for_parsing()`
#'   * build a list of the possible `strptime` Expressions for the data & formats
#'   combinations
#'
#' @inheritParams process_data_for_parsing
#'
#' @return a list of `strptime` Expressions we can use with `coalesce`
#' @noRd
attempt_parsing <- function(x, orders) {
  # translate orders into possible formats
  formats <- build_formats(orders)

  # depending on the orders argument we need to do some processing to the input
  # data. `process_data_for_parsing()` uses the passed `orders` and not the
  # derived `formats`
  processed_data <- process_data_for_parsing(x, orders)

  # build a list of expressions for parsing each processed_data element and
  # format combination
  parse_attempt_exprs_list <- map(processed_data, build_strptime_exprs, formats)

  # if all orders are in c("ym", "my", "yq", "qy") only attempt to parse the
  # augmented version(s) of x
  if (all(orders %in% c("ym", "Ym", "my", "mY", "yq", "Yq", "qy", "qY"))) {
    parse_attempt_exprs_list$processed_x <- list()
  }

  # we need the output to be a list of expressions (currently it is a list of
  # lists of expressions due to the shape of the processed data. we have one list
  # of expressions for each element of/ list in processed_data) -> we need to
  # remove a level of hierarchy from the list
  purrr::flatten(parse_attempt_exprs_list)
}

#' Build `strptime` expressions
#'
#' This function takes several `formats`, iterates over them and builds a
#' `strptime` Expression for each of them. Given these Expressions are evaluated
#' row-wise we can leverage this behaviour and introduce a condition. If `x` has
#' a separator, use the `format` as is, if it doesn't have a separator, remove
#' the `"-"` separator from the `format`.
#'
#' @param x an Expression corresponding to a character or numeric vector of
#' dates to be parsed.
#' @param formats a character vector of formats as returned by
#' `build_format_from_order`
#'
#' @return a list of Expressions
#' @noRd
build_strptime_exprs <- function(x, formats) {
  # returning an empty list helps when iterating
  if (is.null(x)) {
    return(list())
  }

  map(
    formats,
    ~ build_expr(
      "strptime",
      x,
      options = list(format = .x, unit = 0L, error_is_null = TRUE)
    )
  )
}

# helper function to copy variables and attributes from one nc file to another. This will do
# conversion of the variables as well as on the min/max values
copyvals <- function(nc1, var1, nc2, var2, dim2, units2 = NA, conv = NULL, missval = -6999, verbose = FALSE) {

  vals <- ncdf4::ncvar_get(nc = nc1, varid = var1)
  vals[vals == -6999 | vals == -9999] <- NA
  if (!is.null(conv)) {
    vals <- lapply(vals, conv)
  }
  if (is.na(units2)) {
    units2 <- ncdf4::ncatt_get(nc = nc1, varid = var1, attname = "units", verbose = verbose)$value
  }
  var <- ncdf4::ncvar_def(name = var2, units = units2, dim = dim2, missval = missval, verbose = verbose)
  nc2 <- ncdf4::ncvar_add(nc = nc2, v = var, verbose = verbose)
  ncdf4::ncvar_put(nc = nc2, varid = var2, vals = vals)

  # copy and convert attributes
  att <- ncdf4::ncatt_get(nc1, var1, "long_name")
  if (att$hasatt) {
    val <- att$value
    ncdf4::ncatt_put(nc = nc2, varid = var2, attname = "long_name", attval = val)
  }

  att <- ncdf4::ncatt_get(nc1, var1, "valid_min")
  if (att$hasatt) {
    val <- ifelse(is.null(conv), att$value, conv(att$value))
    ncdf4::ncatt_put(nc = nc2, varid = var2, attname = "valid_min", attval = val)
  }

  att <- ncdf4::ncatt_get(nc1, var1, "valid_max")
  if (att$hasatt) {
    val <- ifelse(is.null(conv), att$value, conv(att$value))
    ncdf4::ncatt_put(nc = nc2, varid = var2, attname = "valid_max", attval = val)
  }

  att <- ncdf4::ncatt_get(nc1, var1, "comment")
  if (att$hasatt) {
    val <- sub(", -9999.* = missing value, -6999.* = unreported value", "", att$value)
    ncdf4::ncatt_put(nc = nc2, varid = var2, attname = "comment", attval = val)
  }
} # copyvals

getLatLon <- function(nc1) {
  loc <- ncdf4::ncatt_get(nc = nc1, varid = 0, attname = "site_location")
  if (loc$hasatt) {
    lat <- as.numeric(substr(loc$value, 20, 28))
    lon <- as.numeric(substr(loc$value, 40, 48))
    return(c(lat, lon))
  } else {
    lat <- ncdf4::ncatt_get(nc = nc1, varid = 0, attname = "geospatial_lat_min")
    lon <- ncdf4::ncatt_get(nc = nc1, varid = 0, attname = "geospatial_lon_min")
    if (lat$hasatt && lon$hasatt) {
      return(c(as.numeric(lat$value), as.numeric(lon$value)))
    }
  }
 PEcAn.logger::logger.severe("Could not get site location for file.")
} # getLatLon


##' Get meteorology variables from Ameriflux L2 netCDF files and convert to netCDF CF format
##'
##' @name met2CF.Ameriflux
##' @title met2CF.Ameriflux
##' @export
##' @param in.path location on disk where inputs are stored
##' @param in.prefix prefix of input and output files
##' @param outfolder location on disk where outputs will be stored
##' @param start_date the start date of the data to be downloaded (will only use the year part of the date)
##' @param end_date the end date of the data to be downloaded (will only use the year part of the date)
##' @param overwrite should existing files be overwritten
##' @param verbose should ouput of function be extra verbose
##'
##' @author Josh Mantooth, Mike Dietze, Elizabeth Cowdery, Ankur Desai
met2CF.Ameriflux <- function(in.path, in.prefix, outfolder, start_date, end_date,
                             overwrite = FALSE, verbose = FALSE, ...) {


  # get start/end year code works on whole years only
  start_year <- lubridate::year(start_date)
  end_year   <- lubridate::year(end_date)

  if (!file.exists(outfolder)) {
    dir.create(outfolder)
  }

  rows <- end_year - start_year + 1
  results <- data.frame(file = character(rows),
                        host = character(rows),
                        mimetype = character(rows),
                        formatname = character(rows),
                        startdate = character(rows),
                        enddate = character(rows),
                        dbfile.name = in.prefix,
                        stringsAsFactors = FALSE)
  for (year in start_year:end_year) {
    old.file <- file.path(in.path, paste(in.prefix, year, "nc", sep = "."))
    new.file <- file.path(outfolder, paste(in.prefix, year, "nc", sep = "."))

    # create array with results
    row <- year - start_year + 1
    results$file[row]       <- new.file
    results$host[row]       <- PEcAn.remote::fqdn()
    results$startdate[row]  <- paste0(year, "-01-01 00:00:00")
    results$enddate[row]    <- paste0(year, "-12-31 23:59:59")
    results$mimetype[row]   <- "application/x-netcdf"
    results$formatname[row] <- "CF"

    if (file.exists(new.file) && !overwrite) {
     PEcAn.logger::logger.debug("File '", new.file, "' already exists, skipping to next file.")
      next
    }

    # open raw ameriflux
    nc1 <- ncdf4::nc_open(old.file, write = TRUE)

    # get dimension and site info
    tdim <- nc1$dim[["DTIME"]]

    # create new coordinate dimensions based on site location lat/lon
    latlon <- getLatLon(nc1)

    # Ameriflux L2 files are in 'local time' - figure this out and add to time units attribute Check
    # if timezone is already in time units, if not, figure it out from lat/lon and add it in
    tdimunit <- unlist(strsplit(tdim$units, " "))
    tdimtz <- substr(tdimunit[length(tdimunit)], 1, 1)
    if ((tdimtz == "+") || (tdimtz == "-")) {
      lst <- tdimunit[length(tdimunit)]  #already in definition, leave it alone
    } else {
      if (is.null(getOption("geonamesUsername"))) {
        options(geonamesUsername = "carya")  #login to geoname server
      }
      lst <- geonames::GNtimezone(latlon[1], latlon[2], radius = 0)$gmtOffset
      if (lst >= 0) {
        lststr <- paste("+", lst, sep = "")
      } else {
        lststr <- as.character(lst)
      }
      tdim$units <- paste(tdim$units, lststr, sep = " ")
    }

    lat <- ncdf4::ncdim_def(name = "latitude", units = "", vals = 1:1, create_dimvar = FALSE)
    lon <- ncdf4::ncdim_def(name = "longitude", units = "", vals = 1:1, create_dimvar = FALSE)
    time <- ncdf4::ncdim_def(name = "time", units = tdim$units, vals = tdim$vals,
                      create_dimvar = TRUE, unlim = TRUE)
    dim <- list(lat, lon, time)

    # copy lat attribute to latitude
    var <- ncdf4::ncvar_def(name = "latitude", units = "degree_north", dim = list(lat, lon), missval = as.numeric(-9999))
    nc2 <- ncdf4::nc_create(filename = new.file, vars = var, verbose = verbose)
    ncdf4::ncvar_put(nc = nc2, varid = "latitude", vals = latlon[1])

    # copy lon attribute to longitude
    var <- ncdf4::ncvar_def(name = "longitude", units = "degree_east", dim = list(lat, lon), missval = as.numeric(-9999))
    nc2 <- ncdf4::ncvar_add(nc = nc2, v = var, verbose = verbose)
    ncdf4::ncvar_put(nc = nc2, varid = "longitude", vals = latlon[2])

    # Convert all variables
    # This will include conversions or computations to create values from original file.
    # In case of conversions the steps will pretty much always be:
    # a) get values from original file
    # b) set -6999 and -9999 to NA
    # c) do unit conversions
    # d) create output variable
    # e) write results to new file

    # convert RH to SH
    # this conversion needs to come before others to reinitialize dimension used by copyvals (lat/lon/time)
    rh <- ncdf4::ncvar_get(nc = nc1, varid = "RH")
    rh[rh == -6999 | rh == -9999] <- NA
    rh <- rh/100
    ta <- ncdf4::ncvar_get(nc = nc1, varid = "TA")
    ta[ta == -6999 | ta == -9999] <- NA
    ta <- PEcAn.utils::ud_convert(ta, "degC", "K")
    sh <- rh2qair(rh = rh, T = ta)
    var <- ncdf4::ncvar_def(name = "specific_humidity", units = "kg/kg", dim = dim,
                     missval = -6999, verbose = verbose)
    nc2 <- ncdf4::ncvar_add(nc = nc2, v = var, verbose = verbose)
    ncdf4::ncvar_put(nc = nc2, varid = "specific_humidity", vals = sh)

    # convert TA to air_temperature
    copyvals(nc1 = nc1, var1 = "TA", nc2 = nc2,
             var2 = "air_temperature", units2 = "K",
             dim2 = dim, conv = function(x) { PEcAn.utils::ud_convert(x, "degC", "K") },
             verbose = verbose)

    # convert PRESS to air_pressure
    copyvals(nc1 = nc1, var1 = "PRESS", nc2 = nc2,
             var2 = "air_pressure", units2 = "Pa",
             dim2 = dim,
             conv = function(x) { PEcAn.utils::ud_convert(x, "kPa", "Pa") },
             verbose = verbose)

    # convert CO2 to mole_fraction_of_carbon_dioxide_in_air
    copyvals(nc1 = nc1, var1 = "CO2", nc2 = nc2,
             var2 = "mole_fraction_of_carbon_dioxide_in_air",
             units2 = "mole/mole",
             dim2 = dim,
             conv = function(x) { PEcAn.utils::ud_convert(x, "ppm", "mol/mol") },
             verbose = verbose)

    # convert TS1 to soil_temperature
    copyvals(nc1 = nc1, var1 = "TS1", nc2 = nc2,
             var2 = "soil_temperature", units2 = "K",
             dim2 = dim,
             conv = function(x) { PEcAn.utils::ud_convert(x, "degC", "K") },
             verbose = verbose)

    # copy RH to relative_humidity
    copyvals(nc1 = nc1, var1 = "RH", nc2 = nc2,
             var2 = "relative_humidity", dim2 = dim,
             verbose = verbose)

    # convert VPD to water_vapor_saturation_deficit HACK : conversion will make all values < 0 to be
    # NA
    copyvals(nc1 = nc1, var1 = "VPD", nc2 = nc2,
             var2 = "water_vapor_saturation_deficit", units2 = "Pa",
             dim2 = dim,
             conv = function(x) { ifelse(x < 0, NA, PEcAn.utils::ud_convert(x, "kPa", "Pa")) },
             verbose = verbose)

    # copy Rg to surface_downwelling_shortwave_flux_in_air
    copyvals(nc1 = nc1, var1 = "Rg", nc2 = nc2,
             var2 = "surface_downwelling_shortwave_flux_in_air",
             dim2 = dim,
             verbose = verbose)

    # copy Rgl to surface_downwelling_longwave_flux_in_air
    copyvals(nc1 = nc1, var1 = "Rgl", nc2 = nc2,
             var2 = "surface_downwelling_longwave_flux_in_air",
             dim2 = dim,
             verbose = verbose)

    # convert PAR to surface_downwelling_photosynthetic_photon_flux_in_air
    copyvals(nc1 = nc1, var1 = "PAR", nc2 = nc2,
             var2 = "surface_downwelling_photosynthetic_photon_flux_in_air", units2 = "mol m-2 s-1",
             dim2 = dim,
             conv = function(x) { PEcAn.utils::ud_convert(x, "umol m-2 s-1", "mol m-2 s-1") },
             verbose = verbose)

    # copy WD to wind_direction (not official CF)
    copyvals(nc1 = nc1, var1 = "WD", nc2 = nc2,
             var2 = "wind_direction", dim2 = dim,
             verbose = verbose)

    # copy WS to wind_speed
    copyvals(nc1 = nc1, var1 = "WS", nc2 = nc2,
             var2 = "wind_speed", dim2 = dim,
             verbose = verbose)

    # convert PREC to precipitation_flux
    t <- tdim$vals
    min <- 0.02083 / 30  # 0.02083 time = 30 minutes
    timestep <- round(x = mean(diff(t)) / min, digits = 1)  # round to nearest 0.1 minute
    copyvals(nc1 = nc1, var1 = "PREC", nc2 = nc2,
             var2 = "precipitation_flux", units2 = "kg/m^2/s",
             dim2 = dim,
             conv = function(x) { x / timestep / 60 },
             verbose = verbose)

    # convert wind speed and wind direction to eastward_wind and northward_wind
    wd <- ncdf4::ncvar_get(nc = nc1, varid = "WD")  #wind direction
    wd[wd == -6999 | wd == -9999] <- NA
    ws <- ncdf4::ncvar_get(nc = nc1, varid = "WS")  #wind speed
    ws[ws == -6999 | ws == -9999] <- NA
    ew <- ws * cos(wd * (pi / 180))
    nw <- ws * sin(wd * (pi / 180))
    max <- ncdf4::ncatt_get(nc = nc1, varid = "WS", "valid_max")$value

    var <- ncdf4::ncvar_def(name = "eastward_wind", units = "m/s", dim = dim, missval = -6999, verbose = verbose)
    nc2 <- ncdf4::ncvar_add(nc = nc2, v = var, verbose = verbose)
    ncdf4::ncvar_put(nc = nc2, varid = "eastward_wind", vals = ew)
    ncdf4::ncatt_put(nc = nc2, varid = "eastward_wind", attname = "valid_min", attval = -max)
    ncdf4::ncatt_put(nc = nc2, varid = "eastward_wind", attname = "valid_max", attval = max)

    var <- ncdf4::ncvar_def(name = "northward_wind", units = "m/s", dim = dim, missval = -6999, verbose = verbose)
    nc2 <- ncdf4::ncvar_add(nc = nc2, v = var, verbose = verbose)
    ncdf4::ncvar_put(nc = nc2, varid = "northward_wind", vals = nw)
    ncdf4::ncatt_put(nc = nc2, varid = "northward_wind", attname = "valid_min", attval = -max)
    ncdf4::ncatt_put(nc = nc2, varid = "northward_wind", attname = "valid_max", attval = max)

    # add global attributes from original file
    cp.global.atts <- ncdf4::ncatt_get(nc = nc1, varid = 0)
    for (j in seq_along(cp.global.atts)) {
      ncdf4::ncatt_put(nc = nc2, varid = 0, attname = names(cp.global.atts)[j], attval = cp.global.atts[[j]])
    }

    # done, close both files
    ncdf4::nc_close(nc1)
    ncdf4::nc_close(nc2)
  }  ## end loop over years

  return(invisible(results))
} # met2CF.Ameriflux

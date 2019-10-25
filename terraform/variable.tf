// VARIABLES

// supply the domain name you registered for this project
variable "domain_name" {
}
// supply the local path to the index file
variable "index_path" {
}
// supply the local path for the error file
variable "error_path" {
}
// supply zone_id of the existing hosted zone linked to your domain in route53
variable "zone_id" {
}
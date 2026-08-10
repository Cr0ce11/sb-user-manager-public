.tagName == $tag and
.isDraft == true and
.isPrerelease == false and
(.assets | length) == 2 and
(.assets | map(.name) | sort) == [
  "sb-user-manager.sh",
  "sb-user-manager.sh.sha256"
] and
([.assets[] | select(
  (.name == "sb-user-manager.sh" and .digest == $manager_digest) or
  (.name == "sb-user-manager.sh.sha256" and .digest == $checksum_digest)
)] | length) == 2

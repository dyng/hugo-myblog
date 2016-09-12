deploy:
	hugo --cleanDestinationDir
	git checkout HEAD public/CNAME
	git add -A && git commit -m 'Update blog'
	git subtree push -P public public master
